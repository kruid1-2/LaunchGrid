import AppKit
import SwiftUI

final class LauncherRootHostingView<Content: View>: NSView {
    var onBackgroundClick: (() -> Void)?

    private let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        let childPoint = convert(point, to: hostingView)
        if let hitView = hostingView.hitTest(childPoint), hitView !== hostingView {
            return hitView
        }

        return self
    }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}
