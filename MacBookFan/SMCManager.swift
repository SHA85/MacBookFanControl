import Foundation
import IOKit

enum SensorCategory: Equatable {
    case wifi, battery, cpu, gpu, power, trackpad, ssd
}

struct SensorReading: Identifiable, Equatable {
    let id: String
    let name: String
    let value: Double
    let category: SensorCategory
    let isDiskDrive: Bool
}

// MARK: - Private IOHID Declarations
// These return/accept Core Foundation objects, so they must be declared as CF/AnyObject types.
// (Declaring them as OpaquePointer makes `CopyServices as? [OpaquePointer]` fail, silently
// dropping every CPU/GPU/SSD sensor.)
@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ match: CFDictionary) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timeout: Int64) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

private let kIOHIDEventTypeTemperature: Int64 = 15

/// Reads a sysctl integer such as "hw.perflevel1.logicalcpu"; nil if unavailable.
private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : nil
}

/// Trailing number of a sensor name ("PMU tdie12" → 12), used for a stable order.
private func sensorNumber(_ name: String) -> Int {
    Int(name.reversed().prefix { $0.isNumber }.reversed().map(String.init).joined()) ?? 0
}

class SMCManager {
    static let shared = SMCManager()
    private var connection: io_connect_t = 0
    private var cachedTempKeys: [String] = []
    private var ssdModelName: String = "APPLE SSD"
    
    private init() {
        openConnection()
        scanTemperatureKeys()
        fetchSSDModelName()
    }
    
    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }
    
    private func openConnection() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
    }
    
    // Mac ရဲ့ SSD Model နာမည်အစစ် (ဥပမာ APPLE SSD AP1024Z) ကို ရယူခြင်း
    private func fetchSSDModelName() {
        let task = Process()
        task.launchPath = "/usr/sbin/ioreg"
        task.arguments = ["-c", "AppleANS3CGNvmeController", "-r", "-d", "1"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            for line in output.components(separatedBy: "\n") {
                if line.contains("\"Model\"") {
                    let parts = line.components(separatedBy: "=")
                    if parts.count > 1 {
                        let cleaned = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                        if !cleaned.isEmpty {
                            self.ssdModelName = cleaned
                            return
                        }
                    }
                }
            }
        }
    }
    
    private func stringToUInt32(_ str: String) -> UInt32 {
        var result: UInt32 = 0
        for char in str.utf8.prefix(4) {
            result = (result << 8) | UInt32(char)
        }
        return result
    }
    
    private func uint32ToString(_ val: UInt32) -> String {
        let chars: [UInt8] = [
            UInt8((val >> 24) & 0xff),
            UInt8((val >> 16) & 0xff),
            UInt8((val >> 8) & 0xff),
            UInt8(val & 0xff)
        ]
        return String(bytes: chars, encoding: .ascii) ?? ""
    }
    
    private func callSMC(key: UInt32, data8: UInt8, data32: UInt32 = 0, dataSize: UInt32 = 0, payload: [UInt8] = []) -> (kern_return_t, [UInt8]) {
        var inputBytes = [UInt8](repeating: 0, count: 80)
        var outputBytes = [UInt8](repeating: 0, count: 80)
        
        var k = key
        withUnsafeBytes(of: &k) { inputBytes.replaceSubrange(0..<4, with: $0) }
        
        var ds = dataSize
        withUnsafeBytes(of: &ds) { inputBytes.replaceSubrange(28..<32, with: $0) }
        
        inputBytes.replaceSubrange(42..<43, with: [data8])
        
        var d32 = data32
        withUnsafeBytes(of: &d32) { inputBytes.replaceSubrange(44..<48, with: $0) }
        
        // Offset 48..80: 32-byte data payload (used for writes)
        for (i, b) in payload.prefix(32).enumerated() {
            inputBytes[48 + i] = b
        }
        
        var outputSize = 80
        let result = IOConnectCallStructMethod(connection, 2, &inputBytes, 80, &outputBytes, &outputSize)
        return (result, outputBytes)
    }
    
    private func scanTemperatureKeys() {
        guard connection != 0 else { return }
        guard let totalKeys = readValue(forKey: "#KEY") else { return }
        
        var foundKeys: [String] = []
        for i in 0..<UInt32(totalKeys) {
            let (res, out) = callSMC(key: 0, data8: 8, data32: i)
            if res == kIOReturnSuccess {
                let keyInt = out.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let keyStr = uint32ToString(keyInt)
                if keyStr.hasPrefix("T") {
                    foundKeys.append(keyStr)
                }
            }
        }
        self.cachedTempKeys = foundKeys.sorted()
    }
    
    func readValue(forKey key: String) -> Double? {
        guard connection != 0 else { return nil }
        let keyCode = stringToUInt32(key)
        
        let (infoRes, infoOut) = callSMC(key: keyCode, data8: 9)
        guard infoRes == kIOReturnSuccess else { return nil }
        
        let dataSize = infoOut.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
        let dataTypeInt = infoOut.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) }
        let dataType = uint32ToString(dataTypeInt)
        
        guard dataSize > 0 && dataSize <= 32 else { return nil }
        
        let (readRes, readOut) = callSMC(key: keyCode, data8: 5, dataSize: dataSize)
        guard readRes == kIOReturnSuccess else { return nil }
        
        let bytes = Array(readOut[48..<(48 + Int(dataSize))])
        
        switch dataType {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let val = bytes.withUnsafeBytes { $0.load(as: Float.self) }
            return Double(val)
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let bigEndian = bytes.withUnsafeBytes { $0.load(as: Int16.self) }
            return Double(Int16(bigEndian: bigEndian)) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let bigEndian = bytes.withUnsafeBytes { $0.load(as: UInt16.self) }
            return Double(UInt16(bigEndian: bigEndian)) / 4.0
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            let bigEndian = bytes.withUnsafeBytes { $0.load(as: UInt16.self) }
            return Double(UInt16(bigEndian: bigEndian))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            let bigEndian = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            return Double(UInt32(bigEndian: bigEndian))
        case "ui8 ":
            return Double(bytes.first ?? 0)
        default:
            return nil
        }
    }
    
    func getFanRPM(fanIndex: Int = 0) -> Double? {
        return readValue(forKey: "F\(fanIndex)Ac")
    }
    
    /// Number of fans reported by the SMC ("FNum"). Returns 0 on fanless Macs.
    func fanCount() -> Int {
        return Int(readValue(forKey: "FNum") ?? 0)
    }
    
    // MARK: - Writing
    
    /// Returns the payload size and 4-char data type of an SMC key, or nil if the key doesn't exist.
    func keyInfo(forKey key: String) -> (size: UInt32, type: String)? {
        guard connection != 0 else { return nil }
        let (res, out) = callSMC(key: stringToUInt32(key), data8: 9)
        guard res == kIOReturnSuccess else { return nil }
        // SMC-level result code lives at offset 40; non-zero means "key not found" etc.
        guard out[40] == 0 else { return nil }
        let size = out.withUnsafeBytes { $0.load(fromByteOffset: 28, as: UInt32.self) }
        let type = uint32ToString(out.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt32.self) })
        guard size > 0 && size <= 32 else { return nil }
        return (size, type)
    }
    
    func keyExists(_ key: String) -> Bool {
        return keyInfo(forKey: key) != nil
    }
    
    /// Writes raw bytes to an SMC key (kSMCWriteKey = 6). Writing normally requires root.
    func writeBytes(forKey key: String, bytes: [UInt8]) -> Bool {
        guard let info = keyInfo(forKey: key) else { return false }
        var payload = Array(bytes.prefix(Int(info.size)))
        while payload.count < Int(info.size) { payload.append(0) }
        let (res, out) = callSMC(key: stringToUInt32(key), data8: 6, dataSize: info.size, payload: payload)
        return res == kIOReturnSuccess && out[40] == 0
    }
    
    func writeUInt8(forKey key: String, value: UInt8) -> Bool {
        return writeBytes(forKey: key, bytes: [value])
    }
    
    /// Writes a numeric value, encoding it according to the key's SMC data type.
    func writeFloat(forKey key: String, value: Float) -> Bool {
        guard let info = keyInfo(forKey: key) else { return false }
        let bytes: [UInt8]
        switch info.type {
        case "flt ":
            let bits = value.bitPattern // little-endian on Apple Silicon
            bytes = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        case "fpe2":
            let raw = UInt16(max(0, min(16383, value)) * 4)
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui16":
            let raw = UInt16(max(0, min(65535, value)))
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui8 ":
            bytes = [UInt8(max(0, min(255, value)))]
        default:
            return false
        }
        return writeBytes(forKey: key, bytes: bytes)
    }
    
    // Mac Fan Control ပုံစံအတိုင်း Sensor အားလုံးကို စနစ်တကျ စုစည်းပေးခြင်း
    func getFormattedSensors() -> [SensorReading] {
        var list: [SensorReading] = []
        
        // 1. Airport Proximity
        if let wifi = readValue(forKey: "TW0P"), wifi > 10 && wifi < 110 {
            list.append(SensorReading(id: "TW0P", name: "Airport Proximity", value: wifi, category: .wifi, isDiskDrive: false))
        }
        
        // 2. Battery & Battery Gas Gauge
        let batTemps = ["TB1T", "TB2T"].compactMap { readValue(forKey: $0) }.filter { $0 > 10 && $0 < 90 }
        if !batTemps.isEmpty {
            let avgBat = batTemps.reduce(0, +) / Double(batTemps.count)
            list.append(SensorReading(id: "TB_AVG", name: "Battery", value: avgBat, category: .battery, isDiskDrive: false))
        }
        if let gasGauge = readValue(forKey: "TB0T"), gasGauge > 10 && gasGauge < 90 {
            list.append(SensorReading(id: "TB0T", name: "Battery Gas Gauge", value: gasGauge, category: .battery, isDiskDrive: false))
        }
        
        // 3. IOHID CPU, GPU, SSD Sensors
        var cpuDies: [(n: Int, temp: Double)] = []
        var gpuDies: [(n: Int, temp: Double)] = []
        var ssdTemps: [Double] = []
        
        if let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue() {
            let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
            _ = IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
            
            let services = (IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject]) ?? []
            for service in services {
                guard let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
                let temp = IOHIDEventGetFloatValue(event, Int32(kIOHIDEventTypeTemperature << 16))
                guard temp > 10.0 && temp < 125.0 else { continue }
                let prod = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String ?? ""
                
                if prod.hasPrefix("PMU tdie") {
                    cpuDies.append((sensorNumber(prod), temp))
                } else if prod.hasPrefix("PMU2 tdie") {
                    gpuDies.append((sensorNumber(prod), temp))
                } else if prod.contains("NAND") {
                    ssdTemps.append(temp)
                }
            }
        }
        // Service order isn't guaranteed; sort by sensor number so rows don't shuffle between refreshes.
        cpuDies.sort { $0.n < $1.n }
        gpuDies.sort { $0.n < $1.n }
        
        // Approximate per-core rows: Apple doesn't publish which die sensor sits on which core, so we
        // assign them in order using this chip's real E/P core counts (perflevel1 = E, perflevel0 = P).
        let eCount = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        let pCount = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        let cpuECores = cpuDies.prefix(eCount).map(\.temp)
        let cpuPCores = cpuDies.dropFirst(eCount).prefix(pCount).map(\.temp)
        let gpuClusters = gpuDies.map(\.temp)
        
        // CPU Core Average & Individual Cores
        let allCPU = cpuDies.map(\.temp)  // average over every CPU die sensor
        if !allCPU.isEmpty {
            let avgCPU = allCPU.reduce(0, +) / Double(allCPU.count)
            list.append(SensorReading(id: "CPU_AVG", name: "CPU Core Average", value: avgCPU, category: .cpu, isDiskDrive: false))
            for (idx, val) in cpuECores.enumerated() {
                list.append(SensorReading(id: "CPU_E\(idx+1)", name: "CPU Efficiency Core \(idx+1)", value: val, category: .cpu, isDiskDrive: false))
            }
            for (idx, val) in cpuPCores.enumerated() {
                list.append(SensorReading(id: "CPU_P\(idx+1)", name: "CPU Performance Core \(idx+1)", value: val, category: .cpu, isDiskDrive: false))
            }
        }
        // GPU Clusters
        if !gpuClusters.isEmpty {
            let half = max(1, (gpuClusters.count + 1) / 2)
            let clusterAverages = stride(from: 0, to: gpuClusters.count, by: half).map { start -> Double in
                let slice = gpuClusters[start..<min(start + half, gpuClusters.count)]
                return slice.reduce(0, +) / Double(slice.count)
            }
            for (idx, val) in clusterAverages.enumerated() {
                list.append(SensorReading(id: "GPU_\(idx+1)", name: "GPU Cluster \(idx+1)", value: val, category: .gpu, isDiskDrive: false))
            }
            let avgGPU = gpuClusters.reduce(0, +) / Double(gpuClusters.count)
            list.append(SensorReading(id: "GPU_AVG", name: "GPU Cluster Average", value: avgGPU, category: .gpu, isDiskDrive: false))
        }
        // 4. Power Manager & Trackpad
        let powerKeys = cachedTempKeys.filter { $0.hasPrefix("TP") || $0.hasPrefix("Tp") }
        let powerVals = powerKeys.compactMap { readValue(forKey: $0) }.filter { $0 > 15 && $0 < 110 }
        if !powerVals.isEmpty {
            let pAvg = powerVals.reduce(0, +) / Double(powerVals.count)
            list.append(SensorReading(id: "PWR_AVG", name: "Power Manager Die Average", value: pAvg, category: .power, isDiskDrive: false))
            if let pSupply = powerVals.last {
                list.append(SensorReading(id: "PWR_SUP", name: "Power Supply Proximity", value: pSupply, category: .power, isDiskDrive: false))
            }
        }
        if let trackpad = readValue(forKey: "Ts0P") ?? readValue(forKey: "Ts1P"), trackpad > 10 && trackpad < 90 {
            list.append(SensorReading(id: "TRACKPAD", name: "Trackpad Actuator", value: trackpad, category: .trackpad, isDiskDrive: false))
        }
        // 5. Disk Drives (SSD)
        if !ssdTemps.isEmpty {
            let avgSSD = ssdTemps.reduce(0, +) / Double(ssdTemps.count)
            list.append(SensorReading(id: "SSD_MAIN", name: ssdModelName, value: avgSSD, category: .ssd, isDiskDrive: true))
        } else if let smcSSD = readValue(forKey: "TH0x"), smcSSD > 10 && smcSSD < 90 {
            list.append(SensorReading(id: "SSD_MAIN", name: ssdModelName, value: smcSSD, category: .ssd, isDiskDrive: true))
        }
        return list
    }
}
