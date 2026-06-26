import AppKit
import SwiftUI

@MainActor
final class LauncherWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel = LauncherViewModel()
    private let pager = PagerViewModel()
    private let iconCache = IconCache()
    private let pagingInputController = PagingInputController()
    private let pagingSurfaceController = PagingSurfaceController()
    private var screenObserver: NSObjectProtocol?
    private var pointerSequence: PointerSequence?

    private struct PointerSequence {
        let mouseDownLocation: CGPoint
        let mouseDownWasInteractive: Bool
        let mouseDownAppID: String?
        var didMoveBeyondClickTolerance = false
        var didPageDuringPointerSequence = false
    }

    init() {
        let screen = MouseScreenResolver.currentMouseScreen()
        let panel = LauncherPanel(frame: screen.frame)
        super.init(window: panel)
        viewModel.updateScreenLayout(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)

        panel.delegate = self
        panel.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        panel.mouseEventHandler = { [weak self] event in
            self?.handleMouseEvent(event) ?? false
        }
        panel.pointerPagingActivityHandler = { [weak self] in
            self?.markPointerPagingActivity()
        }
        panel.scrollWheelHandler = { [weak self] event in
            self?.pagingInputController.handleScrollWheel(event) ?? false
        }
        panel.swipeHandler = { [weak self] event in
            self?.pagingInputController.handleSwipe(event) ?? false
        }

        let rootHostingView = LauncherRootHostingView(
            rootView: LauncherView(
                viewModel: viewModel,
                pager: pager,
                iconCache: iconCache,
                onDismiss: { [weak self] in
                    self?.hideLauncher()
                },
                onPagerUpdated: { [weak self] in
                    self?.refreshPagingSurface()
                }
            )
        )
        rootHostingView.frame = panel.contentView?.bounds ?? panel.frame
        rootHostingView.autoresizingMask = [.width, .height]
        panel.contentView = rootHostingView

        installScreenObserver()
        viewModel.loadApplicationsIfNeeded()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        let pagingSurfaceController = pagingSurfaceController
        Task { @MainActor in
            pagingSurfaceController.stopAndRelease()
        }
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
        refreshPagingSurface()
    }

    func hideLauncher() {
        pagingInputController.stop()
        pagingSurfaceController.stopAndRelease()
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
            Task { @MainActor in
                self.applyScreen(screen)
            }
        }
    }

    private func applyScreen(_ screen: NSScreen) {
        window?.setFrame(screen.frame, display: true)
        viewModel.updateScreenLayout(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        pagingSurfaceController.invalidate(reason: "screen")
        configurePagingInput()
        refreshPagingSurface()
    }

    private func configurePagingInput() {
        pagingInputController.configuration = PagingInputController.Configuration(
            state: { [weak self] in
                guard let self else {
                    return .empty
                }

                let layout = self.currentLayout()
                let viewportWidth = max(1, self.currentPagingViewportFrame(layout: layout).width)
                return PagingInputController.State(
                    currentPage: self.pager.currentPage,
                    pageCount: self.pager.pageCount,
                    isTransitioning: false,
                    threshold: layout.scrollThreshold,
                    pageWidth: viewportWidth,
                    animationDuration: layout.pageAnimationDuration
                )
            },
            onBegin: { [weak self] _, direction in
                guard let self, let context = self.pagingSurfaceContext() else {
                    return false
                }

                return self.pagingSurfaceController.beginGesture(context: context, destination: direction)
            },
            onTrackOffset: { [weak self] offset in
                self?.pagingSurfaceController.track(offset: offset)
            },
            onCommit: { [weak self] direction, duration, releaseVelocity in
                guard let self else {
                    return
                }

                self.pagingSurfaceController.finish(
                    direction: direction,
                    duration: duration,
                    releaseVelocity: releaseVelocity,
                    commitPage: { [weak self] in
                        self?.pager.completeSurfacePageTransition(direction)
                    }
                )
            },
            onCancel: { [weak self] duration, releaseVelocity in
                self?.pagingSurfaceController.cancel(duration: duration, releaseVelocity: releaseVelocity)
            }
        )
    }

    private func currentLayout() -> LaunchpadLayout {
        let size = window?.frame.size ?? NSScreen.main?.frame.size ?? CGSize(width: 1024, height: 768)
        return LaunchpadMetrics.layout(for: size, screenInsets: viewModel.screenInsets)
    }

    private func pagingSurfaceContext() -> PagingSurfaceController.Context? {
        guard let contentView = window?.contentView else {
            return nil
        }

        let layout = currentLayout()
        return PagingSurfaceController.Context(
            contentView: contentView,
            viewportFrame: currentPagingViewportFrame(layout: layout),
            pages: pager.pages,
            currentPage: pager.currentPage,
            layout: layout,
            iconCache: iconCache,
            onLaunch: { [weak self] app in
                guard let self, !self.pager.isInteractionLocked else {
                    return
                }

                self.viewModel.launch(app) { [weak self] in
                    self?.hideLauncher()
                }
            }
        )
    }

    private func currentPagingViewportFrame(layout: LaunchpadLayout) -> CGRect {
        guard let contentView = window?.contentView else {
            return CGRect(origin: .zero, size: CGSize(width: layout.pageWidth, height: layout.gridHeight))
        }

        let x = layout.contentFrame.midX - layout.pageWidth / 2
        let y = contentView.isFlipped
            ? layout.gridTop
            : contentView.bounds.height - layout.gridTop - layout.gridHeight
        return CGRect(
            x: x,
            y: y,
            width: layout.pageWidth,
            height: layout.gridHeight
        )
    }

    private func refreshPagingSurface() {
        guard window?.isVisible == true, let context = pagingSurfaceContext() else {
            return
        }

        pagingSurfaceController.installOrUpdate(context: context)
    }

    private func handleMouseEvent(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true, NSApp.isActive, let contentView = window?.contentView else {
            return false
        }

        switch event.type {
        case .leftMouseDown:
            let mouseDownApp = pagingSurfaceController.appItem(atWindowPoint: event.locationInWindow)
            pointerSequence = PointerSequence(
                mouseDownLocation: event.locationInWindow,
                mouseDownWasInteractive: mouseDownApp != nil
                    || isNonAppInteractiveWindowPoint(event.locationInWindow, contentView: contentView),
                mouseDownAppID: mouseDownApp?.id
            )
            return false
        case .leftMouseDragged:
            guard var sequence = pointerSequence else {
                return false
            }

            let distance = hypot(
                event.locationInWindow.x - sequence.mouseDownLocation.x,
                event.locationInWindow.y - sequence.mouseDownLocation.y
            )
            if distance > 5 {
                sequence.didMoveBeyondClickTolerance = true
                pointerSequence = sequence
            }
            return false
        case .leftMouseUp:
            guard let sequence = pointerSequence else {
                return false
            }

            pointerSequence = nil
            let upLocation = event.locationInWindow
            let upDistance = hypot(
                upLocation.x - sequence.mouseDownLocation.x,
                upLocation.y - sequence.mouseDownLocation.y
            )
            guard upDistance <= 5,
                  !sequence.didMoveBeyondClickTolerance,
                  !sequence.didPageDuringPointerSequence else {
                return false
            }

            if let mouseDownAppID = sequence.mouseDownAppID,
               let mouseUpApp = pagingSurfaceController.appItem(atWindowPoint: upLocation),
               mouseUpApp.id == mouseDownAppID {
                pagingSurfaceController.cancelPointerInteraction()
                viewModel.launch(mouseUpApp) { [weak self] in
                    self?.hideLauncher()
                }
                return true
            }

            guard !sequence.mouseDownWasInteractive,
                  !isNonAppInteractiveWindowPoint(upLocation, contentView: contentView),
                  pagingSurfaceController.appItem(atWindowPoint: upLocation) == nil else {
                return false
            }

            pagingSurfaceController.cancelPointerInteraction()
            hideLauncher()
            return true
        default:
            return false
        }
    }

    private func markPointerPagingActivity() {
        guard var sequence = pointerSequence else {
            return
        }

        sequence.didPageDuringPointerSequence = true
        pointerSequence = sequence
    }

    private func isNonAppInteractiveWindowPoint(_ location: CGPoint, contentView: NSView) -> Bool {
        let windowPoint = CGPoint(x: location.x, y: location.y)
        let flippedPoint = CGPoint(
            x: location.x,
            y: contentView.bounds.height - location.y
        )
        let layout = currentLayout()
        let contentCenterX = layout.contentFrame.midX

        let searchTop = layout.contentFrame.minY + layout.topPadding
        let searchFrame = CGRect(
            x: contentCenterX - layout.searchWidth / 2,
            y: searchTop,
            width: layout.searchWidth,
            height: layout.searchHeight
        ).insetBy(dx: -12, dy: -10)

        let pageIndicatorFrame = CGRect(
            x: contentCenterX - 90,
            y: layout.pageIndicatorCenterY - 26,
            width: 180,
            height: 52
        )

        let candidatePoints = [flippedPoint, windowPoint]
        return candidatePoints.contains(where: { searchFrame.contains($0) })
            || candidatePoints.contains(where: { pageIndicatorFrame.contains($0) })
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
