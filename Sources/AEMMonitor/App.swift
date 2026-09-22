import SwiftUI

@main
struct AEMMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible window — everything is in the menu bar popover.
        Settings {
            EmptyView()
        }
    }
}
