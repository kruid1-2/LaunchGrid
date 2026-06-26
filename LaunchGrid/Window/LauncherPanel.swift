import AppKit

final class LauncherPanel: NSPanel {
    var keyDownHandler: ((NSEvent) -> Bool)?
    var mouseEventHandler: ((NSEvent) -> Bool)?
    var scrollWheelHandler: ((NSEvent) -> Bool)?
    var swipeHandler: ((NSEvent) -> Bool)?
    var pointerPagingActivityHandler: (() -> Void)?

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        title = "LaunchGrid"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Keep the launcher visually translucent, but avoid a fully transparent
        // window backing. A completely clear borderless panel can allow blank
        // regions to fall out of the normal event target path on macOS.
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.001)
        hasShadow = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isMovable = false
        level = .normal
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .scrollWheel:
            // This method is already running on the launcher panel, so the
            // downstream handler must not reject the event merely because
            // event.window is temporarily nil during a gesture phase.
            if scrollWheelHandler?(event) == true {
                pointerPagingActivityHandler?()
                return
            }
        case .swipe:
            if swipeHandler?(event) == true {
                pointerPagingActivityHandler?()
                return
            }
        case .keyDown:
            if keyDownHandler?(event) == true {
                return
            }
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            if mouseEventHandler?(event) == true {
                return
            }
        default:
            break
        }

        super.sendEvent(event)
    }

}
