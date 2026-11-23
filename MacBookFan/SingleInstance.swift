import AppKit
import Darwin
import notify

/// Keeps a single macbook_fan running. Several copies would each re-write their own fan target every
/// tick and fight over the fan.
///
/// Rule: the newest copy wins. This makes both "Relaunch as Administrator" (the new root copy
/// replaces the normal one) and re-running from Xcode (the fresh build replaces the old one) work.
///
/// A new copy announces itself through a Darwin notification. Unlike NSDistributedNotificationCenter,
/// Darwin notifications are system-wide, so they also reach copies running as root. Every older copy
/// then quits normally, which hands the fan back to macOS. Copies that don't react (e.g. builds from
/// before this guard existed) are sent SIGTERM after a short grace period, where permissions allow.
enum SingleInstance {
    private static let notificationName = "digit.macbook_fan.instance-launched"
    private static var token: Int32 = NOTIFY_TOKEN_INVALID

    /// Call once, as early as possible during launch.
    static func start() {
        // React to copies launched after us.
        notify_register_dispatch(notificationName, &token, .main) { _ in
            if newerInstanceExists() {
                NSApp.terminate(nil)
            }
        }

        // Tell older copies we're here.
        notify_post(notificationName)

        // Fallback for older copies that didn't quit on their own.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            for other in olderInstances() {
                _ = kill(other.pid, SIGTERM) // EPERM for root copies when we're not root: ignored.
            }
        }
    }

    // MARK: Process discovery

    private struct Instance {
        let pid: pid_t
        let started: Double // seconds since 1970
    }

    private static func newerInstanceExists() -> Bool {
        guard let me = current() else { return false }
        return others().contains { isNewer($0, than: me) }
    }

    private static func olderInstances() -> [Instance] {
        guard let me = current() else { return [] }
        return others().filter { isNewer(me, than: $0) }
    }

    private static func isNewer(_ a: Instance, than b: Instance) -> Bool {
        a.started != b.started ? a.started > b.started : a.pid > b.pid
    }

    private static func current() -> Instance? {
        allInstances().first { $0.pid == getpid() }
    }

    private static func others() -> [Instance] {
        allInstances().filter { $0.pid != getpid() }
    }

    /// Every process (any user) whose name matches ours, via sysctl so root copies are visible too.
    private static func allInstances() -> [Instance] {
        let myName = ProcessInfo.processInfo.processName
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let capacity = size / MemoryLayout<kinfo_proc>.stride + 16 // room for processes spawned meanwhile
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride

        return procs.prefix(count).compactMap { kp -> Instance? in
            var comm = kp.kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard name == myName else { return nil }
            // Skip root processes: that's macbook_fan's helper daemon (same executable), not another app copy.
            guard kp.kp_eproc.e_ucred.cr_uid != 0 else { return nil }
            let tv = kp.kp_proc.p_un.__p_starttime
            return Instance(pid: kp.kp_proc.p_pid, started: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        }
    }
}
