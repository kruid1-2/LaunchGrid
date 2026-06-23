import AppKit
import SwiftUI

struct PagingEventView: NSViewRepresentable {
    let currentPage: Int
    let pageCount: Int
    let isTransitioning: Bool
    let pageWidth: CGFloat
    let threshold: CGFloat
    let maxDragOffset: CGFloat
    let onDrag: (CGFloat) -> Void
    let onCommit: (Int) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PagingInputNSView {
        let view = PagingInputNSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: PagingInputNSView, context: Context) {
        context.coordinator.configuration = Configuration(
            currentPage: currentPage,
            pageCount: pageCount,
            isTransitioning: isTransitioning,
            pageWidth: pageWidth,
            threshold: threshold,
            maxDragOffset: maxDragOffset,
            onDrag: onDrag,
            onCommit: onCommit,
            onCancel: onCancel
        )
    }

    final class Coordinator {
        var configuration = Configuration.empty
        private weak var view: PagingInputNSView?
        private var monitor: Any?
        private var accumulatedDelta: CGFloat = 0
        private var didTurnPageInGesture = false
        private var lockedUntil: TimeInterval = 0
        private var lastEventTime: TimeInterval = 0
        private var resetWorkItem: DispatchWorkItem?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func attach(to view: PagingInputNSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window else {
                return event
            }

            if let eventWindow = event.window {
                guard eventWindow === window else {
                    return event
                }

                let localPoint = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(localPoint) else {
                    return event
                }
            } else {
                guard window.frame.contains(NSEvent.mouseLocation) else {
                    return event
                }
            }

            process(event)
            return nil
        }

        private func process(_ event: NSEvent) {
            let now = Date().timeIntervalSinceReferenceDate

            guard configuration.pageCount > 1 else {
                configuration.onCancel()
                resetGesture()
                return
            }

            if event.phase.contains(.began) || now - lastEventTime > 0.36 {
                startGesture()
            }
            lastEventTime = now

            if configuration.isTransitioning || now < lockedUntil {
                return
            }

            if event.momentumPhase != [] {
                if didTurnPageInGesture {
                    lockedUntil = now + 0.35
                }
                return
            }

            let dominantDelta = normalizedDominantDelta(from: event)
            guard abs(dominantDelta) >= 0.01 else {
                return
            }

            accumulatedDelta += dominantDelta

            if !didTurnPageInGesture {
                let limited = min(configuration.maxDragOffset, abs(accumulatedDelta))
                configuration.onDrag(-limited * sign(accumulatedDelta))
            }

            if !didTurnPageInGesture, abs(accumulatedDelta) >= configuration.threshold {
                didTurnPageInGesture = true
                lockedUntil = now + 0.38

                let step = accumulatedDelta > 0 ? 1 : -1
                let targetPage = configuration.currentPage + step
                if targetPage >= 0 && targetPage < configuration.pageCount {
                    configuration.onCommit(step)
                } else {
                    configuration.onCancel()
                }
                return
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                configuration.onCancel()
                resetAfterDelay(0.18)
            } else if event.phase == [] {
                resetAfterDelay(0.28)
            }
        }

        private func normalizedDominantDelta(from event: NSEvent) -> CGFloat {
            let horizontal = event.scrollingDeltaX
            let vertical = -event.scrollingDeltaY
            let dominant = abs(horizontal) >= abs(vertical) ? horizontal : vertical
            return dominant * (event.hasPreciseScrollingDeltas ? 1 : 22)
        }

        private func startGesture() {
            resetWorkItem?.cancel()
            accumulatedDelta = 0
            didTurnPageInGesture = false
            configuration.onCancel()
        }

        private func resetGesture() {
            accumulatedDelta = 0
            didTurnPageInGesture = false
        }

        private func resetAfterDelay(_ delay: TimeInterval) {
            resetWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.resetGesture()
            }
            resetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func sign(_ value: CGFloat) -> CGFloat {
            value >= 0 ? 1 : -1
        }
    }

    struct Configuration {
        let currentPage: Int
        let pageCount: Int
        let isTransitioning: Bool
        let pageWidth: CGFloat
        let threshold: CGFloat
        let maxDragOffset: CGFloat
        let onDrag: (CGFloat) -> Void
        let onCommit: (Int) -> Void
        let onCancel: () -> Void

        static let empty = Configuration(
            currentPage: 0,
            pageCount: 1,
            isTransitioning: false,
            pageWidth: 1,
            threshold: 80,
            maxDragOffset: 90,
            onDrag: { _ in },
            onCommit: { _ in },
            onCancel: { }
        )
    }
}

final class PagingInputNSView: NSView {
    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
