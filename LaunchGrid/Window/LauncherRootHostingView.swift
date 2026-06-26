import AppKit
import SwiftUI

final class LauncherRootHostingView<Content: View>: NSView {
    private let hostingView: NSHostingView<Content>

    init(rootView: Content) {
        self.hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        wantsLayer = true
        // Give the full content area a tiny nonzero backing alpha. This is not
        // visually perceptible, but it keeps blank regions in the window's
        // event surface instead of behaving like transparent pass-through.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else {
            return nil
        }

        for subview in subviews.reversed() {
            let childPoint = convert(point, to: subview)
            if let hitView = subview.hitTest(childPoint) {
                return hitView
            }
        }

        return hostingView
    }

}
