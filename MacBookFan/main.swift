import Foundation
import SwiftUI

// One executable, two roles:
//  • launchd starts it as root with `--helper` → the fan-writing helper daemon (no UI).
//  • Otherwise it's the normal menu bar app, running as the logged-in user.
if CommandLine.arguments.contains(FanHelper.launchArgument) {
    HelperDaemon.run()
} else {
    macbook_fanApp.main()
}
