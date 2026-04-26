import SwiftUI
import AppKit

@main
struct MeetingBarApp: App {
    // We use an AppDelegate because menu-bar-only apps need fine control
    // over NSApplication activation policy and the status item lifecycle.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings scene is required by SwiftUI but we never show it.
        // The real UI lives in the AppDelegate's status item + popover.
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .accessory = no Dock icon, no main menu, no window on launch.
        // This is the correct policy for a menu bar utility.
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
