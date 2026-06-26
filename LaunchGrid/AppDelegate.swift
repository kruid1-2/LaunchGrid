import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcherWindowController: LauncherWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let controller = LauncherWindowController()
        launcherWindowController = controller
        controller.showLauncher()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        launcherWindowController?.showLauncher()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillResignActive(_ notification: Notification) {
        launcherWindowController?.hideLauncher()
    }
}
