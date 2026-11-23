import SwiftUI

// MARK: - Temperature unit
/// Everything is stored and computed in Celsius; this only affects what's displayed.
enum TemperatureUnit: String {
    case celsius, fahrenheit

    static let storageKey = "macbook_fan.temperatureUnit"

    var symbol: String { self == .celsius ? "°C" : "°F" }

    func fromCelsius(_ c: Double) -> Double { self == .celsius ? c : c * 9 / 5 + 32 }
    func toCelsius(_ v: Double) -> Double { self == .celsius ? v : (v - 32) * 5 / 9 }

    /// Whole-degree number in this unit, e.g. 36 or 97.
    func value(_ celsius: Double) -> Int { Int(fromCelsius(celsius).rounded()) }
    /// e.g. "36°C" / "97°F".
    func format(_ celsius: Double) -> String { "\(value(celsius))\(symbol)" }
}

// MARK: - Shared building blocks
struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

extension View {
    /// Rounded card used for fan cards, stat tiles and the sensor list.
    func cardStyle(cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// °C | °F segmented control with a sliding pill behind the active unit. Every view reads the same
/// stored setting, so switching anywhere updates everywhere.
struct UnitSwitch: View {
    @AppStorage(TemperatureUnit.storageKey) private var unit: TemperatureUnit = .celsius
    @Namespace private var pillNamespace

    /// Matches a `.controlSize(.large)` bordered button (e.g. the "Details" button beside it).
    var height: CGFloat = 28

    private static let trackColor = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255) // #2C2C2E
    private static let pillColor  = Color(red: 0x48 / 255, green: 0x48 / 255, blue: 0x4A / 255) // #48484A
    private static let inset: CGFloat = 2

    var body: some View {
        HStack(spacing: 0) {
            segment(.celsius)
            segment(.fahrenheit)
        }
        .padding(Self.inset)
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Self.trackColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .help("Switch temperature unit")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Temperature unit")
    }

    private func segment(_ option: TemperatureUnit) -> some View {
        let isActive = unit == option
        return Button {
            guard !isActive else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                unit = option
            }
        } label: {
            Text(option.symbol)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundColor(isActive ? .white : .secondary)
                .frame(width: 36)
                .frame(maxHeight: .infinity)
                .background {
                    if isActive {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Self.pillColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "unitPill", in: pillNamespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Simple heat level used for colouring (thresholds in °C).
enum HeatLevel {
    case cool, warm, hot

    init(celsius: Double) {
        self = celsius < 50 ? .cool : (celsius < 75 ? .warm : .hot)
    }

    var label: String {
        switch self {
        case .cool: return "Cool"
        case .warm: return "Warm"
        case .hot: return "Hot"
        }
    }

    var color: Color {
        switch self {
        case .cool: return .green
        case .warm: return .orange
        case .hot: return .red
        }
    }
}

// MARK: - Key sensors (shown in the popover list)
struct DashboardSensor: Identifiable {
    let id: String       // SensorReading id
    let title: String
    let symbol: String
    let tint: Color

    static let all: [DashboardSensor] = [
        .init(id: "TW0P", title: "Airport Proximity", symbol: "wifi", tint: .cyan),
        .init(id: "TB_AVG", title: "Battery", symbol: "battery.75percent", tint: .green),
        .init(id: "TB0T", title: "Battery Gas Gauge", symbol: "gauge.with.dots.needle.50percent", tint: .mint),
        .init(id: "CPU_AVG", title: "CPU Core Average", symbol: "cpu", tint: .blue),
        .init(id: "GPU_AVG", title: "GPU Cluster Avg", symbol: "square.grid.3x3.fill", tint: .purple),
        .init(id: "PWR_AVG", title: "Power Avg", symbol: "bolt.fill", tint: .yellow),
        .init(id: "TRACKPAD", title: "Trackpad Actuator", symbol: "hand.point.up.left.fill", tint: .pink),
        .init(id: "SSD_MAIN", title: "Disk Drive Avg", symbol: "internaldrive.fill", tint: .orange),
    ]
}

// MARK: - Detail list (Details window)
struct SensorDetailView: View {
    @ObservedObject var store: FanControlStore
    @AppStorage(TemperatureUnit.storageKey) private var unit: TemperatureUnit = .celsius
    @Environment(\.dismissWindow) private var dismissWindow

    private var mainSensors: [SensorReading] { store.sensors.filter { !$0.isDiskDrive } }
    private var diskSensors: [SensorReading] { store.sensors.filter { $0.isDiskDrive } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                PaneHeader(title: "All Sensors", subtitle: "\(store.sensors.count) temperature sensors · live")
                Spacer()
                UnitSwitch()
                // Closes this window only; the app keeps running in the menu bar.
                Button {
                    dismissWindow(id: "details")
                    NSApp.deactivate()
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                .help("Hide — keeps running in the menu bar")
            }

            VStack(spacing: 0) {
                HStack {
                    Text("Sensor")
                    Spacer()
                    Text("Value \(unit.symbol)")
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .frame(height: 30)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(mainSensors.enumerated()), id: \.element.id) { index, sensor in
                            SensorTableRow(sensor: sensor, isEven: index % 2 == 0)
                        }

                        if !diskSensors.isEmpty {
                            HStack {
                                Text("DISK DRIVES")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(Color.primary.opacity(0.05))

                            ForEach(Array(diskSensors.enumerated()), id: \.element.id) { index, disk in
                                SensorTableRow(sensor: disk, isEven: (mainSensors.count + index) % 2 == 0)
                            }
                        }
                    }
                }
            }
            .cardStyle()
        }
        .padding(20)
        .frame(width: 520, height: 580)
    }
}

// MARK: - Table Row View
struct SensorTableRow: View {
    let sensor: SensorReading
    @AppStorage(TemperatureUnit.storageKey) private var unit: TemperatureUnit = .celsius
    let isEven: Bool

    var body: some View {
        HStack(spacing: 10) {
            SensorIconView(category: sensor.category)
                .frame(width: 22, alignment: .center)

            Text(sensor.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Circle()
                .fill(HeatLevel(celsius: sensor.value).color)
                .frame(width: 6, height: 6)

            Text("\(unit.value(sensor.value))")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(isEven ? Color.primary.opacity(0.03) : Color.clear)
    }
}

// MARK: - Sensor Icons
struct SensorIconView: View {
    let category: SensorCategory

    private var symbol: (name: String, color: Color) {
        switch category {
        case .wifi: return ("wifi", .cyan)
        case .battery: return ("battery.75percent", .green)
        case .cpu: return ("cpu", .blue)
        case .gpu: return ("square.grid.3x3.fill", .purple)
        case .power: return ("bolt.fill", .yellow)
        case .trackpad: return ("hand.point.up.left.fill", .pink)
        case .ssd: return ("internaldrive.fill", .orange)
        }
    }

    var body: some View {
        Image(systemName: symbol.name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(symbol.color)
    }
}


// MARK: - Left Pane Fan Card (status + inline controls)
extension FanControlMode {
    /// Compact labels so the segmented control fits in the fan pane.
    var shortName: String {
        switch self {
        case .auto: return "Auto"
        case .constant: return "Constant"
        case .sensorBased: return "Sensor"
        }
    }
}

struct FanControlCard: View {
    let fan: FanState
    @ObservedObject var store: FanControlStore
    @AppStorage(TemperatureUnit.storageKey) private var unit: TemperatureUnit = .celsius

    // Slider values live here while dragging and are committed on release, so the store
    // (and the whole window) isn't republished on every pixel of slider movement.
    @State private var draftRPM: Double?
    @State private var draftStart: Double?
    @State private var draftMax: Double?

    private var fraction: Double {
        guard let rpm = fan.currentRPM, fan.maxRPM > 0 else { return 0 }
        return max(0, min(1, rpm / fan.maxRPM))
    }

    /// Settings as currently shown, including uncommitted slider drafts.
    private var shown: FanSettings {
        var s = fan.settings
        if let v = draftRPM { s.constantRPM = v }
        if let v = draftStart { s.startTemp = v }
        if let v = draftMax { s.maxTemp = v }
        return s
    }

    /// Applies a settings change on the next run-loop turn. macOS controls (Picker, Toggle, Slider)
    /// can call their setters while SwiftUI is still updating views; mutating the store there
    /// publishes `fans` mid-update ("Publishing changes from within view updates is not allowed").
    private func apply(_ change: @escaping (inout FanSettings) -> Void, then completion: @escaping () -> Void = {}) {
        let store = store, index = fan.index
        DispatchQueue.main.async {
            store.update(fanIndex: index, change)
            completion()
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<FanSettings, T>) -> Binding<T> {
        Binding(
            get: { fan.settings[keyPath: keyPath] },
            set: { newValue in apply { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func draftBinding(_ draft: Binding<Double?>, _ keyPath: WritableKeyPath<FanSettings, Double>) -> Binding<Double> {
        Binding(
            get: { draft.wrappedValue ?? fan.settings[keyPath: keyPath] },
            set: { draft.wrappedValue = $0 }
        )
    }

    private func commitDraft(_ draft: Binding<Double?>, _ keyPath: WritableKeyPath<FanSettings, Double>) {
        guard let value = draft.wrappedValue else { return }
        // Keep showing the draft until the store has the new value, so the thumb doesn't jump back.
        apply({ $0[keyPath: keyPath] = value }, then: { draft.wrappedValue = nil })
    }

    /// Well-known sensors (plus the current selection) that have no reading right now.
    private var unavailableSensors: [(id: String, name: String)] {
        var items = FanControlStore.wellKnownSensors
        let selected = fan.settings.sensorID
        if !items.contains(where: { $0.id == selected }) { items.append((selected, selected)) }
        return items.filter { item in !store.sensors.contains { $0.id == item.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "fanblades.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(fan.settings.mode == .auto ? .secondary : .accentColor)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill((fan.settings.mode == .auto ? Color.secondary : Color.accentColor).opacity(0.16)))
                Text(fan.name)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if fan.lastWriteFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .help("Last SMC write failed")
                }
            }

            // Status
            VStack(spacing: 6) {
                HStack {
                    Text("Current:").foregroundColor(.secondary)
                    Spacer()
                    Text(fan.currentRPM.map { "\(Int($0)) RPM" } ?? "N/A")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(fraction > 0.75 ? .red : (fraction > 0.45 ? .orange : .green))
                HStack {
                    Text("Target:").foregroundColor(.secondary)
                    Spacer()
                    Text(fan.targetRPM.map { $0 <= 0 ? "Off" : "\(Int($0)) RPM" } ?? "System")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 12))

            Divider()

            // Mode
            Picker("Mode", selection: binding(\.mode)) {
                ForEach(FanControlMode.allCases) { Text($0.shortName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch fan.settings.mode {
            case .auto:
                Text("macOS controls this fan automatically.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

            case .constant:
                constantControls

            case .sensorBased:
                sensorControls
            }
        }
        .padding(14)
        .cardStyle()
    }

    private var constantControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speed").font(.system(size: 12))
                Spacer()
                Text("\(Int(shown.constantRPM)) RPM")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            // No `step:` — on macOS it draws a tick mark per step. Snap to 100 RPM in the binding instead.
            Slider(value: rpmSliderBinding, in: rpmRange) { editing in
                if !editing { commitDraft($draftRPM, \.constantRPM) }
            }
            HStack(spacing: 4) {
                ForEach([0.0, 0.33, 0.66, 1.0], id: \.self) { f in
                    Button(f == 0 ? "Min" : (f == 1 ? "Max" : "\(Int(f * 100))%")) {
                        let rpm = fan.minRPM + f * (fan.maxRPM - fan.minRPM)
                        apply { $0.constantRPM = (rpm / 100).rounded() * 100 }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .controlSize(.small)
        }
    }

    private var rpmRange: ClosedRange<Double> {
        fan.minRPM...max(fan.minRPM + 1, fan.maxRPM)
    }

    /// The constant-speed draft, snapped to the nearest 100 RPM and kept inside the fan's range.
    private var rpmSliderBinding: Binding<Double> {
        let base = draftBinding($draftRPM, \.constantRPM)
        let range = rpmRange
        return Binding(
            get: { base.wrappedValue },
            set: { base.wrappedValue = min(max(($0 / 100).rounded() * 100, range.lowerBound), range.upperBound) }
        )
    }

    private var sensorControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sensor", selection: binding(\.sensorID)) {
                ForEach(store.sensors) { sensor in
                    Text("\(sensor.name) (\(unit.format(sensor.value)))").tag(sensor.id)
                }
                // Sensors with no data on this Mac: listed but greyed out, never selectable.
                ForEach(unavailableSensors, id: \.id) { item in
                    Text("\(item.name) — no data").tag(item.id)
                        .disabled(true)
                }
            }
            .labelsHidden()
            .disabled(store.sensors.isEmpty)

            TempSlider(title: "Start increasing at", value: draftBinding($draftStart, \.startTemp), range: 20...95) {
                commitDraft($draftStart, \.startTemp)
            }
            TempSlider(title: "Full speed at", value: draftBinding($draftMax, \.maxTemp), range: 25...105) {
                commitDraft($draftMax, \.maxTemp)
            }

            Toggle("Turn fan off below start temperature", isOn: binding(\.stopBelowStart))
                .font(.system(size: 11))
                .controlSize(.small)

            if store.sensors.isEmpty {
                Text("No temperature sensors are available on this Mac.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct TempSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onCommit: () -> Void = {}
    @AppStorage(TemperatureUnit.storageKey) private var unit: TemperatureUnit = .celsius

    /// The Celsius binding seen in the selected unit.
    private var displayValue: Binding<Double> {
        Binding(
            get: { unit.fromCelsius(value).rounded() },
            set: { value = unit.toCelsius($0.rounded()) } // whole degrees, without a tick-marked `step:`
        )
    }

    private var displayRange: ClosedRange<Double> {
        unit.fromCelsius(range.lowerBound).rounded()...unit.fromCelsius(range.upperBound).rounded()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(unit.format(value))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            Slider(value: displayValue, in: displayRange) { editing in
                if !editing { onCommit() }
            }
        }
    }
}
