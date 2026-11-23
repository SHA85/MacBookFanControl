import Foundation
import Security

/// Root helper: listens on the `macbook_fan.helper` Mach service and performs fan writes for the app.
///
/// Security:
/// - Only clients signed with the same code-signing identifier and Team ID as this executable
///   (i.e. macbook_fan itself) can connect (`setConnectionCodeSigningRequirement`).
/// - It only exposes "set speed", "stop" and "automatic" for real fan indices; speeds are clamped
///   to the fan's own min/max by FanController.
/// - When the last client disconnects (app quit or crashed), every fan goes back to automatic
///   and the helper exits. launchd starts it again on demand the next time the app connects,
///   so no macbook_fan process is left running in the background after the app quits.
final class HelperDaemon: NSObject, NSXPCListenerDelegate, FanHelperProtocol {
    private let queue = DispatchQueue(label: "macbook_fan.helper.smc") // serialises all SMC access
    private var connectionCount = 0                              // only touched on `queue`
    private var idleGeneration = 0                               // only touched on `queue`

    /// How long the helper waits with no client before exiting.
    private static let idleTimeout: TimeInterval = 5

    static func run() -> Never {
        guard geteuid() == 0 else {
            NSLog("macbook_fan helper: must be started by launchd as root")
            exit(EXIT_FAILURE)
        }
        guard let requirement = clientRequirement() else {
            NSLog("macbook_fan helper: executable is not signed with a Team ID; refusing to serve")
            exit(EXIT_FAILURE)
        }

        let daemon = HelperDaemon()
        let listener = NSXPCListener(machServiceName: FanHelper.machServiceName)
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = daemon
        listener.resume()
        // If launchd started us but no client ever connects, don't linger.
        daemon.queue.async { daemon.scheduleIdleExit() }
        dispatchMain()
    }

    /// `identifier "<our id>" and anchor apple generic and certificate leaf[subject.OU] = "<our team>"`
    private static func clientRequirement() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = self

        var ended = false
        let end: () -> Void = { [weak self] in
            self?.queue.async {
                guard let self, !ended else { return }
                ended = true
                self.connectionCount -= 1
                if self.connectionCount == 0 {
                    self.restoreAllAutomatic()
                    self.scheduleIdleExit()
                }
            }
        }
        connection.invalidationHandler = end
        connection.interruptionHandler = end

        queue.sync { // sync: a pending idle exit must see this client before it can fire
            self.connectionCount += 1
            self.idleGeneration += 1 // cancels any pending idle exit
        }
        connection.resume()
        return true
    }

    // MARK: FanHelperProtocol

    func setFanSpeed(fanIndex: Int, rpm: Double, reply: @escaping (Bool) -> Void) {
        queue.async {
            guard self.isValidFan(fanIndex), rpm.isFinite else { return reply(false) }
            reply(FanController.shared.setManualSpeed(fanIndex: fanIndex, targetRPM: rpm))
        }
    }

    func stopFan(fanIndex: Int, reply: @escaping (Bool) -> Void) {
        queue.async {
            guard self.isValidFan(fanIndex) else { return reply(false) }
            reply(FanController.shared.stopFan(fanIndex: fanIndex))
        }
    }

    func setAutomatic(fanIndex: Int, releaseTestMode: Bool, reply: @escaping (Bool) -> Void) {
        queue.async {
            guard self.isValidFan(fanIndex) else { return reply(false) }
            reply(FanController.shared.setAutomaticMode(fanIndex: fanIndex, releaseTestMode: releaseTestMode))
        }
    }

    // MARK: Private

    /// Exits after `idleTimeout` unless a client connects first. Call on `queue`.
    private func scheduleIdleExit() {
        idleGeneration += 1
        let generation = idleGeneration
        queue.asyncAfter(deadline: .now() + Self.idleTimeout) { [weak self] in
            guard let self, self.connectionCount == 0, self.idleGeneration == generation else { return }
            NSLog("macbook_fan helper: no clients, exiting")
            exit(EXIT_SUCCESS)
        }
    }

    private func isValidFan(_ index: Int) -> Bool {
        (0..<max(SMCManager.shared.fanCount(), 1)).contains(index)
    }

    private func restoreAllAutomatic() {
        let count = max(SMCManager.shared.fanCount(), 1)
        for i in 0..<count {
            FanController.shared.setAutomaticMode(fanIndex: i, releaseTestMode: i == count - 1)
        }
    }
}
