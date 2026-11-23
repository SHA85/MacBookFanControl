//
//  macbook_fanApp.swift
//  macbook_fan
//
//  Created by YaminAung on 11/22/26.
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only one macbook_fan may control the fans: the newest copy takes over, older ones quit.
        SingleInstance.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start polling sensors and driving the fans right away, before any UI is opened.
        _ = FanControlStore.shared
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave fans forced when the app quits — hand control back to macOS.
        FanControlStore.shared.restoreAutomaticSync()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app: keep running (and controlling the fans) when the Details window is closed.
        false
    }
}

// Entry point is main.swift (it also starts the root helper when launched with --helper).
struct macbook_fanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Status bar item with live CPU temperature + fan RPM; click for the popover.
        MenuBarExtra {
            MenuBarPopover()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        // All Sensors list on its own, opened from the popover's "Detail" button.
        Window("macbook_fan Details", id: "details") {
            SensorDetailView(store: FanControlStore.shared)
        }
        .windowResizability(.contentSize)
    }
}
