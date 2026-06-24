import AppKit
import SwiftUI

final class LauncherWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel = LauncherViewModel()
    private let pager = PagerViewModel()
    private let iconCache = IconCache()
    private let pagingInputController = PagingInputController()
    private var screenObserver: NSObjectProtocol?

    init() {
        let screen = MouseScreenResolver.currentMouseScreen()
        let panel = LauncherPanel(frame: screen.frame)
        super.init(window: panel)
        viewModel.updateScreenLayout(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)

        panel.delegate = self
        panel.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        panel.scrollWheelHandler = { [weak self] event in
            self?.pagingInputController.handleScrollWheel(event) ?? false
        }

        let rootHostingView = LauncherRootHostingView(
            rootView: LauncherView(
                viewModel: viewModel,
                pager: pager,
                iconCache: iconCache,
                onDismiss: { [weak self] in
                    self?.hideLauncher()
                }
            )
        )
        rootHostingView.onBackgroundClick = { [weak self] in
            self?.hideLauncher()
        }
        panel.contentView = rootHostingView

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
        applyScreen(screen)
        configurePagingInput()
        pagingInputController.start(window: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .launchGridFocusSearch, object: nil)
        }
    }

    func hideLauncher() {
        pagingInputController.stop()
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

            let screen = self.window?.screen ?? MouseScreenResolver.currentMouseScreen()
            self.applyScreen(screen)
        }
    }

    private func applyScreen(_ screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
        viewModel.updateScreenLayout(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        configurePagingInput()
    }

    private func configurePagingInput() {
        pagingInputController.configuration = PagingInputController.Configuration(
            state: { [weak self] in
                guard let self else {
                    return .empty
                }

                let layout = self.currentLayout()
                return PagingInputController.State(
                    currentPage: self.pager.currentPage,
                    pageCount: self.pager.pageCount,
                    isTransitioning: self.pager.isPageTransitioning,
                    threshold: layout.scrollThreshold,
                    pageWidth: layout.pageWidth,
                    animationDuration: layout.pageAnimationDuration
                )
            },
            onTrackOffset: { [weak self] offset in
                self?.pager.setInteractiveOffset(offset)
            },
            onCommit: { [weak self] direction, duration in
                guard let self else {
                    return
                }

                self.pager.stepPage(
                    direction,
                    pageWidth: self.currentLayout().pageWidth,
                    animationDuration: duration
                )
            },
            onCancel: { [weak self] duration in
                self?.pager.cancelDrag(animationDuration: duration)
            }
        )
    }

    private func currentLayout() -> LaunchpadLayout {
        let size = window?.frame.size ?? NSScreen.main?.frame.size ?? CGSize(width: 1024, height: 768)
        return LaunchpadMetrics.layout(for: size, screenInsets: viewModel.screenInsets)
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
