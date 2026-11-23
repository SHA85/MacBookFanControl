import Foundation
import Combine

enum FanControlMode: String, CaseIterable, Identifiable, Codable {
    case auto = "Automatic"
    case constant = "Constant RPM"
    case sensorBased = "Sensor-based"
    var id: String { self.rawValue }
}

// MARK: - Low-level SMC fan control

class FanController {
    static let shared = FanController()

    private init() {}

    // MARK: Fan Limits (Min / Max RPM)
    func getMinRPM(fanIndex: Int = 0) -> Double {
        return SMCManager.shared.readValue(forKey: "F\(fanIndex)Mn") ?? 1200.0
    }

    func getMaxRPM(fanIndex: Int = 0) -> Double {
        return SMCManager.shared.readValue(forKey: "F\(fanIndex)Mx") ?? 6500.0
    }

    // MARK: Sensor-Based Curve Calculation
    /// Pure curve math (no SMC access) so the UI can preview it cheaply.
    static func curveRPM(mode: FanControlMode, minRPM: Double, maxRPM: Double, constantRPM: Double,
                         currentTemp: Double, startTemp: Double, maxTemp: Double) -> Double {
        switch mode {
        case .auto:
            return minRPM
        case .constant:
            return max(minRPM, min(maxRPM, constantRPM))
        case .sensorBased:
            if currentTemp <= startTemp {
                return minRPM
            } else if currentTemp >= maxTemp {
                return maxRPM
            } else {
                let ratio = (currentTemp - startTemp) / max(1.0, (maxTemp - startTemp))
                return minRPM + ratio * (maxRPM - minRPM)
            }
        }
    }

    /// Apple Silicon uses "F0Md"; some models expose a lowercase "F0md".
    private func modeKey(fanIndex: Int) -> String {
        let upper = "F\(fanIndex)Md"
        if SMCManager.shared.keyExists(upper) { return upper }
        let lower = "F\(fanIndex)md"
        return SMCManager.shared.keyExists(lower) ? lower : upper
    }

    // MARK: Write Speed to AppleSMC
    @discardableResult
    func setManualSpeed(fanIndex: Int = 0, targetRPM: Double) -> Bool {
        let minRPM = getMinRPM(fanIndex: fanIndex)
        let maxRPM = getMaxRPM(fanIndex: fanIndex)
        let safeRPM = Float(max(minRPM, min(maxRPM, targetRPM)))
        guard enterForcedMode(fanIndex: fanIndex) else { return false }
        return SMCManager.shared.writeFloat(forKey: "F\(fanIndex)Tg", value: safeRPM)
    }

    /// Stops the fan: forced mode with a 0 RPM target. If the SMC refuses a 0 target, hand the fan
    /// back to macOS instead — on Apple Silicon the system keeps the fan off while the Mac is cool.
    @discardableResult
    func stopFan(fanIndex: Int = 0) -> Bool {
        if enterForcedMode(fanIndex: fanIndex),
           SMCManager.shared.writeFloat(forKey: "F\(fanIndex)Tg", value: 0) {
            return true
        }
        return setAutomaticMode(fanIndex: fanIndex, releaseTestMode: false)
    }

    private func enterForcedMode(fanIndex: Int) -> Bool {
        let smc = SMCManager.shared
        let mdKey = modeKey(fanIndex: fanIndex)

        // Put fan into forced mode. On Apple Silicon, thermalmonitord holds the fan
        // until "Ftst" (fan test) is set, so unlock and retry briefly if the first write fails.
        var modeSet = smc.writeUInt8(forKey: mdKey, value: 1)
        if !modeSet, smc.keyExists("Ftst") {
            _ = smc.writeUInt8(forKey: "Ftst", value: 1)
            for _ in 0..<10 where !modeSet {
                usleep(100_000)
                modeSet = smc.writeUInt8(forKey: mdKey, value: 1)
            }
        }
        return modeSet
    }

    /// Returns control of one fan to macOS. Pass `releaseTestMode` once every fan is automatic.
    @discardableResult
    func setAutomaticMode(fanIndex: Int = 0, releaseTestMode: Bool = true) -> Bool {
        let ok = SMCManager.shared.writeUInt8(forKey: modeKey(fanIndex: fanIndex), value: 0)
        if releaseTestMode, SMCManager.shared.keyExists("Ftst") {
            _ = SMCManager.shared.writeUInt8(forKey: "Ftst", value: 0)
        }
        return ok
    }
}

// MARK: - Per-fan settings

struct FanSettings: Codable, Equatable {
    var mode: FanControlMode = .auto
    var constantRPM: Double = 2500
    var sensorID: String = "CPU_AVG"
    var startTemp: Double = 50
    var maxTemp: Double = 85
    /// Sensor mode: turn the fan off while the sensor is below `startTemp`.
    var stopBelowStart: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanSettings()
        mode = try c.decodeIfPresent(FanControlMode.self, forKey: .mode) ?? d.mode
        constantRPM = try c.decodeIfPresent(Double.self, forKey: .constantRPM) ?? d.constantRPM
        sensorID = try c.decodeIfPresent(String.self, forKey: .sensorID) ?? d.sensorID
        startTemp = try c.decodeIfPresent(Double.self, forKey: .startTemp) ?? d.startTemp
        maxTemp = try c.decodeIfPresent(Double.self, forKey: .maxTemp) ?? d.maxTemp
        stopBelowStart = try c.decodeIfPresent(Bool.self, forKey: .stopBelowStart) ?? d.stopBelowStart
    }
}

extension FanController {
    /// How far below the start temperature a running fan must cool before it stops again,
    /// so it doesn't toggle on/off while the sensor hovers around the threshold.
    static let stopHysteresis: Double = 2

    /// Sensor-mode target in RPM; 0 means the fan should be off.
    static func sensorTarget(settings s: FanSettings, minRPM: Double, maxRPM: Double,
                             temp: Double, wasRunning: Bool) -> Double {
        if s.stopBelowStart {
            let offBelow = wasRunning ? s.startTemp - stopHysteresis : s.startTemp
            if temp < offBelow { return 0 }
        }
        return curveRPM(mode: .sensorBased, minRPM: minRPM, maxRPM: maxRPM, constantRPM: 0,
                        currentTemp: temp, startTemp: s.startTemp, maxTemp: s.maxTemp)
    }
}

struct FanState: Identifiable, Equatable {
    let index: Int
    var name: String
    var minRPM: Double
    var maxRPM: Double
    var currentRPM: Double?
    var targetRPM: Double?
    var settings: FanSettings
    var lastWriteFailed = false

    var id: Int { index }
}

// MARK: - Observable store driving the UI and the control loop

final class FanControlStore: ObservableObject {
    static let shared = FanControlStore()

    @Published private(set) var fans: [FanState] = []
    @Published private(set) var sensors: [SensorReading] = []
    @Published private(set) var errorMessage: String?

    /// SMC writes need root, so they go through macbook_fan's root helper (see HelperDaemon). The app
    /// itself always runs as the user — macOS only shows menu bar items for user processes.
    @Published private(set) var helperStatus: HelperStatus = HelperClient.shared.status

    /// True when fan speeds can actually be written.
    var isPrivileged: Bool { helperStatus == .enabled }

    private let writeQueue = DispatchQueue(label: "macbook_fan.smc.write")
    private var pendingWrites = Set<Int>() // fan indices with a write in flight (main thread only)
    private let defaultsKey = "macbook_fan.fanSettings"

    private init() {
        let count = max(SMCManager.shared.fanCount(), 1)
        let saved = loadSettings()
        fans = (0..<count).map { i in
            FanState(
                index: i,
                name: count == 1 ? "Fan" : (i == 0 ? "Left Fan" : (i == 1 ? "Right Fan" : "Fan \(i + 1)")),
                minRPM: FanController.shared.getMinRPM(fanIndex: i),
                maxRPM: FanController.shared.getMaxRPM(fanIndex: i),
                currentRPM: nil,
                targetRPM: nil,
                settings: saved[i] ?? FanSettings()
            )
        }
        startPolling()
    }

    /// Polls sensors and drives the fans every 2 s for the app's whole lifetime — independent of
    /// which windows are open, so fan control keeps working from the menu bar.
    private var pollTimer: Timer?

    private func startPolling() {
        tick()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in self?.tick() }
        // .common keeps it firing while a menu or the menu bar popover is being tracked.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// CPU average if this Mac reports it, otherwise nil.
    var cpuTemperature: Double? { temperature(forSensor: "CPU_AVG") }

    var isAnyFanManual: Bool { fans.contains { $0.settings.mode != .auto } }

    func temperature(forSensor id: String) -> Double? {
        sensors.first { $0.id == id }?.value
    }

    /// Sensor IDs that have reported a value at least once this session.
    private var seenSensorIDs = Set<String>()

    /// Common sensors always listed in the picker (greyed out when this Mac has no data for them).
    static let wellKnownSensors: [(id: String, name: String)] = [
        ("CPU_AVG", "CPU Core Average"),
        ("GPU_AVG", "GPU Cluster Average"),
    ]

    /// Best available sensor to drive a fan curve: CPU average, then any CPU/GPU/power sensor, then anything.
    func preferredSensorID() -> String? {
        if sensors.contains(where: { $0.id == "CPU_AVG" }) { return "CPU_AVG" }
        for category in [SensorCategory.cpu, .gpu, .power] {
            if let s = sensors.first(where: { $0.category == category }) { return s.id }
        }
        return sensors.first?.id
    }

    /// Replaces a sensor selection this Mac has never reported (e.g. the CPU_AVG default on a Mac
    /// without CPU die sensors). Sensors that were seen but briefly dropped out are left alone.
    private func resolveSensors(in fans: inout [FanState]) {
        guard let preferred = preferredSensorID() else { return }
        for i in fans.indices where !seenSensorIDs.contains(fans[i].settings.sensorID) {
            fans[i].settings.sensorID = preferred
        }
    }

    // Called by the UI timer. Builds new values off to the side and publishes only real changes,
    // so SwiftUI doesn't redraw the whole window (and any open popover) every tick.
    func tick() {
        refreshHelperStatus()
        let newSensors = SMCManager.shared.getFormattedSensors()
        if newSensors != sensors { sensors = newSensors }
        seenSensorIDs.formUnion(newSensors.map(\.id))

        var next = fans
        for i in next.indices {
            next[i].currentRPM = SMCManager.shared.getFanRPM(fanIndex: next[i].index)
        }
        let before = next.map(\.settings)
        resolveSensors(in: &next)
        commit(next)
        if next.map(\.settings) != before { saveSettings() }
    }

    func update(fanIndex: Int, _ change: (inout FanSettings) -> Void) {
        var next = fans
        guard let i = next.firstIndex(where: { $0.index == fanIndex }) else { return }
        let previous = next[i].settings
        change(&next[i].settings)
        resolveSensors(in: &next)
        next[i].settings.constantRPM = max(next[i].minRPM, min(next[i].maxRPM, next[i].settings.constantRPM))
        if next[i].settings.maxTemp <= next[i].settings.startTemp {
            next[i].settings.maxTemp = next[i].settings.startTemp + 1
        }
        guard next[i].settings != previous else { return }

        let switchedToAuto = next[i].settings.mode == .auto && previous.mode != .auto
        commit(next)
        saveSettings()
        if switchedToAuto { releaseToAuto(fanIndex: fanIndex) }
    }

    func resetAllToAuto() {
        var next = fans
        for i in next.indices { next[i].settings.mode = .auto }
        commit(next)
        saveSettings()
        for fan in fans { releaseToAuto(fanIndex: fan.index) }
    }

    /// Synchronous restore used on app termination. (The helper also does this by itself when
    /// the app's connection drops, e.g. after a crash.)
    func restoreAutomaticSync() {
        guard isPrivileged, isAnyFanManual else { return }
        writeQueue.sync {
            for (n, fan) in fans.enumerated() {
                _ = HelperClient.shared.setAutomatic(fanIndex: fan.index, releaseTestMode: n == fans.count - 1)
            }
        }
    }

    /// Registers the root helper. The first time, macOS asks for approval in System Settings →
    /// Login Items (we open it); after that, fan control works without any password.
    func enableFanControl() {
        do {
            try HelperClient.shared.enable()
        } catch {
            setError("Couldn't enable fan control: \(error.localizedDescription)")
        }
        refreshHelperStatus()
    }

    func openLoginItemsSettings() {
        HelperClient.shared.openLoginItemsSettings()
    }

    private func refreshHelperStatus() {
        let status = HelperClient.shared.status
        if status != helperStatus { helperStatus = status }
    }

    private func setError(_ message: String?) {
        if errorMessage != message { errorMessage = message }
    }

    // MARK: Private

    /// Recomputes targets, publishes only if something changed, then pushes speeds to the SMC.
    private func commit(_ proposed: [FanState]) {
        var next = proposed
        for i in next.indices {
            next[i].targetRPM = targetRPM(for: next[i])
        }
        if next != fans { fans = next }
        pushToSMC()
    }

    private func targetRPM(for fan: FanState) -> Double? {
        let s = fan.settings
        switch s.mode {
        case .auto:
            return nil
        case .constant:
            return FanController.curveRPM(mode: .constant, minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                                          constantRPM: s.constantRPM, currentTemp: 0,
                                          startTemp: s.startTemp, maxTemp: s.maxTemp)
        case .sensorBased:
            // If the chosen sensor disappeared, fail safe to full speed rather than minimum.
            guard let temp = temperature(forSensor: s.sensorID) else { return fan.maxRPM }
            return FanController.sensorTarget(settings: s, minRPM: fan.minRPM, maxRPM: fan.maxRPM,
                                              temp: temp, wasRunning: (fan.targetRPM ?? 0) > 0)
        }
    }

    private func pushToSMC() {
        guard isPrivileged else { return }
        for fan in fans {
            guard let target = fan.targetRPM, !pendingWrites.contains(fan.index) else { continue }
            let index = fan.index
            pendingWrites.insert(index)
            writeQueue.async { [weak self] in
                let ok = target <= 0
                    ? HelperClient.shared.stopFan(fanIndex: index)
                    : HelperClient.shared.setFanSpeed(fanIndex: index, rpm: target)
                DispatchQueue.main.async { self?.recordWrite(fanIndex: index, ok: ok) }
            }
        }
    }

    private func releaseToAuto(fanIndex: Int) {
        guard isPrivileged else { return }
        let allAuto = !isAnyFanManual
        writeQueue.async { [weak self] in
            let ok = HelperClient.shared.setAutomatic(fanIndex: fanIndex, releaseTestMode: allAuto)
            DispatchQueue.main.async { self?.recordWrite(fanIndex: fanIndex, ok: ok) }
        }
    }

    private func recordWrite(fanIndex: Int, ok: Bool) {
        pendingWrites.remove(fanIndex)
        guard let i = fans.firstIndex(where: { $0.index == fanIndex }) else { return }
        if fans[i].lastWriteFailed == ok { fans[i].lastWriteFailed = !ok }
        let message: String? = fans.contains(where: { $0.lastWriteFailed })
            ? "Couldn't set the fan speed: the helper didn't respond or the SMC refused the change."
            : nil
        if errorMessage != message { errorMessage = message }
    }

    private func loadSettings() -> [Int: FanSettings] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([Int: FanSettings].self, from: data) else { return [:] }
        return decoded
    }

    private func saveSettings() {
        let dict = Dictionary(uniqueKeysWithValues: fans.map { ($0.index, $0.settings) })
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
