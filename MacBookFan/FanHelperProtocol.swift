import Foundation

/// Shared between the app and its root helper.
///
/// The helper is this same macbook_fan executable started by launchd with `--helper` (see main.swift and
/// Helper/macbook_fan.helper.plist). The app runs as the logged-in user — macOS only shows menu bar items
/// for user processes — and asks the helper to do the few SMC writes that need root.
enum FanHelper {
    /// launchd label and XPC Mach service name. Must match Helper/macbook_fan.helper.plist.
    static let machServiceName = "macbook_fan.helper"
    /// File name of the launchd plist inside Contents/Library/LaunchDaemons.
    static let plistName = "macbook_fan.helper.plist"
    /// Command-line flag that makes the executable run as the helper instead of the app.
    static let launchArgument = "--helper"
}

/// Fan-write operations the helper performs on the app's behalf. Every reply is `true` on success.
@objc protocol FanHelperProtocol {
    func setFanSpeed(fanIndex: Int, rpm: Double, reply: @escaping (Bool) -> Void)
    func stopFan(fanIndex: Int, reply: @escaping (Bool) -> Void)
    func setAutomatic(fanIndex: Int, releaseTestMode: Bool, reply: @escaping (Bool) -> Void)
}
