import Foundation
import ServiceManagement

/// Where the root helper stands, as far as the app can tell.
enum HelperStatus: Equatable {
    case notInstalled   // not registered yet (or unregistered)
    case needsApproval  // registered, waiting for the user in System Settings → Login Items
    case enabled        // approved; launchd starts it on demand
}

/// App-side access to the root helper: registration through SMAppService, calls over XPC.
final class HelperClient {
    static let shared = HelperClient()

    private let service = SMAppService.daemon(plistName: FanHelper.plistName)
    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private init() {}

    var status: HelperStatus {
        switch service.status {
        case .requiresApproval: return .needsApproval
        case .enabled: return .enabled
        // A daemon that has never been registered reports .notFound (not .notRegistered), so both
        // mean "not set up yet". A genuinely broken bundle surfaces as an error from register().
        case .notRegistered, .notFound: return .notInstalled
        @unknown default: return .notInstalled
        }
    }

    /// Registers the helper with launchd. The first time, macOS asks the user to approve it in
    /// System Settings; we open that pane for them.
    func enable() throws {
        do {
            try service.register()
        } catch {
            // Registering when approval is still pending reports an error but is not a failure.
            if status != .needsApproval { throw error }
        }
        if status == .needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Calls (blocking — call from a background queue)

    func setFanSpeed(fanIndex: Int, rpm: Double) -> Bool {
        call { $0.setFanSpeed(fanIndex: fanIndex, rpm: rpm, reply: $1) }
    }

    func stopFan(fanIndex: Int) -> Bool {
        call { $0.stopFan(fanIndex: fanIndex, reply: $1) }
    }

    func setAutomatic(fanIndex: Int, releaseTestMode: Bool) -> Bool {
        call { $0.setAutomatic(fanIndex: fanIndex, releaseTestMode: releaseTestMode, reply: $1) }
    }

    // MARK: Private

    private func call(_ body: (FanHelperProtocol, @escaping (Bool) -> Void) -> Void) -> Bool {
        var result = false
        let proxy = currentConnection().synchronousRemoteObjectProxyWithErrorHandler { error in
            NSLog("macbook_fan: helper call failed: \(error.localizedDescription)")
            result = false
        }
        guard let helper = proxy as? FanHelperProtocol else { return false }
        body(helper) { result = $0 }
        return result
    }

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        let c = NSXPCConnection(machServiceName: FanHelper.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
        c.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.connection === c { self.connection = nil }
            self.lock.unlock()
        }
        c.resume()
        connection = c
        return c
    }
}
