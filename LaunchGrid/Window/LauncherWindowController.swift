import AppKit
import SwiftUI

final class LauncherWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel = LauncherViewModel()
    private let iconCache = IconCache()
    private var screenObserver: NSObjectProtocol?

    init() {
        let screen = MouseScreenResolver.currentMouseScreen()
        let panel = LauncherPanel(frame: screen.frame)
        super.init(window: panel)

        panel.delegate = self
        panel.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        panel.contentViewController = NSHostingController(
            rootView: LauncherView(
                viewModel: viewModel,
                iconCache: iconCache,
                onDismiss: { [weak self] in
                    self?.hideLauncher()
                }
            )
        )

        installScreenObserver()
        viewModel.loadApplicationsIfNeeded()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func showLauncher() {
        guard let window else {
            return
        }

        let screen = MouseScreenResolver.currentMouseScreen()
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .launchGridFocusSearch, object: nil)
        }
    }

    func hideLauncher() {
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideLauncher()
        return false
    }

    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.window?.isVisible == true else {
                return
            }

            self.window?.setFrame(MouseScreenResolver.currentMouseScreen().frame, display: true)
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true, NSApp.isActive else {
            return false
        }

        let characters = event.charactersIgnoringModifiers?.lowercased()
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command), characters == "f" {
            NotificationCenter.default.post(name: .launchGridFocusSearch, object: nil)
            return true
        }

        switch event.keyCode {
        case 36, 76:
            viewModel.launchFirstResult { [weak self] in
                self?.hideLauncher()
            }
            return true
        case 53:
            if viewModel.searchText.isEmpty {
                hideLauncher()
            } else {
                viewModel.clearSearch()
                NotificationCenter.default.post(name: .launchGridFocusSearch, object: nil)
            }
            return true
        default:
            return false
        }
    }
}

enum MouseScreenResolver {
    static func currentMouseScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation

        for screen in NSScreen.screens where screen.frame.contains(mouseLocation) {
            return screen
        }

        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
}
