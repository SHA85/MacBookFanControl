import SwiftUI

// MARK: - Status bar label: "<fan icon> 41°C  2,317 rpm"
struct MenuBarLabel: View {
    @ObservedObject private var store = FanControlStore.shared
    @AppStorage(TemperatureUnit.storageKey) private var unit: TemperatureUnit = .celsius

    private var temperatureText: String {
        store.cpuTemperature.map { unit.format($0) } ?? "--"
    }

    private var rpmText: String {
        guard let rpm = store.fans.first?.currentRPM else { return "--" }
        return rpm < 50 ? "Off" : "\(Int(rpm).formatted()) rpm"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "fanblades.fill")
            Text("\(temperatureText)  \(rpmText)")
                .monospacedDigit() // keeps the status item from jittering as digits change
        }
        .accessibilityLabel("CPU \(temperatureText), fan \(rpmText)")
    }
}

// MARK: - Popover shown when the status item is clicked
struct MenuBarPopover: View {
    @ObservedObject private var store = FanControlStore.shared
    @AppStorage(TemperatureUnit.storageKey) private var unit: TemperatureUnit = .celsius
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.dismiss) private var dismiss

    private var fan: FanState? { store.fans.first }

    private var fanStatus: String {
        guard let fan else { return "No fan" }
        switch fan.settings.mode {
        case .auto: return "Controlled by macOS"
        case .constant: return "Constant speed"
        case .sensorBased: return "Following a sensor"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("macbook_fan")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text(fanStatus)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.accentColor) // the app's gold
                }
                Spacer()
                UnitSwitch()
            }

            // Headline numbers
            HStack(spacing: 10) {
                StatTile(
                    title: "CPU",
                    symbol: "cpu",
                    tint: .blue,
                    value: store.cpuTemperature.map { "\(unit.value($0))" } ?? "--",
                    suffix: unit.symbol,
                    level: store.cpuTemperature.map { HeatLevel(celsius: $0) }
                )
                StatTile(
                    title: "Fan",
                    symbol: "fanblades.fill",
                    tint: .accentColor,
                    value: fan?.currentRPM.map { $0 < 50 ? "Off" : Int($0).formatted() } ?? "--",
                    suffix: (fan?.currentRPM ?? 0) < 50 ? "" : "rpm",
                    level: nil
                )
            }

            // Fan controls
            ForEach(store.fans) { fan in
                FanControlCard(fan: fan, store: store)
            }

            // Key temperatures, compact
            VStack(spacing: 0) {
                ForEach(Array(DashboardSensor.all.enumerated()), id: \.element.id) { index, tile in
                    CompactSensorRow(tile: tile, celsius: store.temperature(forSensor: tile.id))
                        .background(index % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .cardStyle()

            HelperBanner(store: store)

            Divider()

            // Footer
            HStack {
                Button {
                    openWindow(id: "details")
                    NSApp.activate()
                    dismiss()
                } label: {
                    Label("Detail", systemImage: "list.bullet.rectangle")
                }
                .help("Show every temperature sensor")

                Button {
                    store.resetAllToAuto()
                } label: {
                    Label("Auto", systemImage: "arrow.counterclockwise")
                }
                .disabled(!store.isAnyFanManual)
                .help("Reset all fans to automatic")

                Spacer()

                // Closes the popover and the Details window. The app keeps running in the
                // background and in the menu bar, still controlling the fans.
                Button {
                    dismissWindow(id: "details")
                    dismiss()
                    NSApp.deactivate()
                } label: {
                    Label("Hide", systemImage: "eye.slash")
                }
                .help("Hide — keeps running in the menu bar")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
                .keyboardShortcut("q")
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(width: 360)
    }
}

// MARK: - Building blocks
struct StatTile: View {
    let title: String
    let symbol: String
    let tint: Color
    let value: String
    let suffix: String
    let level: HeatLevel?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                if let level {
                    Circle().fill(level.color).frame(width: 7, height: 7)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(suffix)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

struct CompactSensorRow: View {
    let tile: DashboardSensor
    let celsius: Double?
    @AppStorage(TemperatureUnit.storageKey) private var unit: TemperatureUnit = .celsius

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tile.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tile.tint)
                .frame(width: 18)
            Text(tile.title)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            if let c = celsius {
                Circle().fill(HeatLevel(celsius: c).color).frame(width: 6, height: 6)
                Text(unit.format(c))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .opacity(celsius == nil ? 0.55 : 1)
    }
}

// MARK: - Helper status / error banner (shown in the popover)
/// Tells the user what fan control needs, based on the root helper's state, or shows the last
/// write error once the helper is running. Renders nothing when everything is fine.
struct HelperBanner: View {
    @ObservedObject var store: FanControlStore

    var body: some View {
        switch store.helperStatus {
        case .notInstalled:
            banner(icon: "lock.fill",
                   text: store.errorMessage
                       ?? "Fan control needs macbook_fan's helper. It runs in the background with the rights to change fan speed.",
                   button: "Enable Fan Control", systemImage: "checkmark.shield") {
                store.enableFanControl()
            }
        case .needsApproval:
            banner(icon: "hand.raised.fill",
                   text: "Turn on macbook_fan in System Settings → General → Login Items & Extensions to allow fan control.",
                   button: "Open System Settings", systemImage: "gearshape") {
                store.openLoginItemsSettings()
            }
        case .enabled:
            if let error = store.errorMessage {
                banner(icon: "exclamationmark.triangle.fill", text: error,
                       button: nil, systemImage: nil, action: nil)
            }
        }
    }

    private func banner(icon: String, text: String, button: String?, systemImage: String?,
                        action: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.orange)
                Text(text)
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let button, let systemImage, let action {
                Button(action: action) {
                    Label(button, systemImage: systemImage)
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}
