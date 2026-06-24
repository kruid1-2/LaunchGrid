import AppKit
import OSLog

enum PagingDirection: String {
    case previous
    case next

    var step: Int {
        switch self {
        case .previous:
            -1
        case .next:
            1
        }
    }
}

final class PagingInputController {
    struct State {
        let currentPage: Int
        let pageCount: Int
        let isTransitioning: Bool
        let threshold: CGFloat
        let pageWidth: CGFloat
        let animationDuration: TimeInterval

        static let empty = State(
            currentPage: 0,
            pageCount: 1,
            isTransitioning: false,
            threshold: 80,
            pageWidth: 1,
            animationDuration: 0.2
        )
    }

    struct Configuration {
        let state: () -> State
        let onTrackOffset: (CGFloat) -> Void
        let onCommit: (PagingDirection, TimeInterval) -> Void
        let onCancel: (TimeInterval) -> Void

        static let empty = Configuration(
            state: { .empty },
            onTrackOffset: { _ in },
            onCommit: { _, _ in },
            onCancel: { _ in }
        )
    }

    private struct ScrollGesture {
        let state: State
        var accumulatedOffset: CGFloat
    }

    var configuration = Configuration.empty

    private let logger = Logger(subsystem: "com.launchgrid.app", category: "paging")
    private weak var window: NSWindow?
    private var activeGesture: ScrollGesture?
    private var finalizeWorkItem: DispatchWorkItem?
    private var suppressMomentumUntil: TimeInterval = 0

    private let scrollResponseMultiplier: CGFloat = 1.0
    private let horizontalDominanceRatio: CGFloat = 1.05
    private let debounceInterval: TimeInterval = 0.34

    deinit {
        stop()
    }

    func start(window: NSWindow) {
        self.window = window
        resetGesture(cancelAnimationDuration: configuration.state().animationDuration)
        logger.notice("Paging root input activated")
    }

    func stop() {
        resetGesture(cancelAnimationDuration: configuration.state().animationDuration)
        window = nil
        logger.notice("Paging root input deactivated")
    }

    func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible, NSApp.isActive else {
            return false
        }

        guard event.window === window else {
            return false
        }

        if event.momentumPhase != [] {
            if activeGesture != nil {
                finishGesture(cancelled: false, reason: "momentum")
            }
            return ProcessInfo.processInfo.systemUptime < suppressMomentumUntil
        }

        let state = configuration.state()
        guard state.pageCount > 1, !state.isTransitioning else {
            return false
        }

        let physicalX = normalizedPhysicalDelta(
            rawDelta: event.scrollingDeltaX,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
        )
        let physicalY = normalizedPhysicalDelta(
            rawDelta: event.scrollingDeltaY,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
        )

        guard activeGesture != nil || canStartScrollPaging(physicalX: physicalX, physicalY: physicalY) else {
            return false
        }

        if activeGesture == nil {
            beginGesture(state: state, event: event)
        }

        applyScrollDelta(physicalX, state: state)

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishGesture(cancelled: event.phase.contains(.cancelled), reason: "phase")
        } else {
            scheduleDebouncedFinish()
        }

        return true
    }

    private func beginGesture(state: State, event: NSEvent) {
        finalizeWorkItem?.cancel()
        activeGesture = ScrollGesture(state: state, accumulatedOffset: 0)
        configuration.onCancel(0)
        logger.notice(
            "Scroll paging began page=\(state.currentPage) inverted=\(event.isDirectionInvertedFromDevice)"
        )
    }

    private func applyScrollDelta(_ physicalX: CGFloat, state: State) {
        guard var gesture = activeGesture else {
            return
        }

        gesture.accumulatedOffset += physicalX * scrollResponseMultiplier
        gesture.accumulatedOffset = min(
            state.pageWidth * 0.96,
            max(-state.pageWidth * 0.96, gesture.accumulatedOffset)
        )
        activeGesture = gesture

        let direction = direction(for: gesture.accumulatedOffset)
        let boundedOffset = visualOffset(gesture.accumulatedOffset, for: direction, state: gesture.state)
        configuration.onTrackOffset(boundedOffset)
    }

    private func finishGesture(cancelled: Bool, reason: StaticString) {
        finalizeWorkItem?.cancel()
        finalizeWorkItem = nil

        guard let gesture = activeGesture else {
            return
        }

        activeGesture = nil
        suppressMomentumUntil = ProcessInfo.processInfo.systemUptime + 0.65

        let direction = direction(for: gesture.accumulatedOffset)
        let shouldCommit = !cancelled && abs(gesture.accumulatedOffset) >= gesture.state.threshold

        guard shouldCommit else {
            logger.notice(
                "Scroll paging cancelled page=\(gesture.state.currentPage) reason=\(reason) offset=\(gesture.accumulatedOffset)"
            )
            configuration.onCancel(gesture.state.animationDuration)
            return
        }

        let targetPage = gesture.state.currentPage + direction.step
        guard targetPage >= 0, targetPage < gesture.state.pageCount else {
            logger.notice(
                "Scroll paging boundary page=\(gesture.state.currentPage) direction=\(direction.rawValue, privacy: .public)"
            )
            configuration.onCancel(gesture.state.animationDuration)
            return
        }

        logger.notice(
            "Scroll paging commit direction=\(direction.rawValue, privacy: .public) from=\(gesture.state.currentPage) to=\(targetPage) offset=\(gesture.accumulatedOffset)"
        )
        configuration.onCommit(direction, gesture.state.animationDuration)
    }

    private func canStartScrollPaging(physicalX: CGFloat, physicalY: CGFloat) -> Bool {
        let absX = abs(physicalX)
        let absY = abs(physicalY)
        return absX > max(0.25, absY * horizontalDominanceRatio)
    }

    private func direction(for offset: CGFloat) -> PagingDirection {
        offset < 0 ? .next : .previous
    }

    private func normalizedPhysicalDelta(
        rawDelta: CGFloat,
        isDirectionInvertedFromDevice: Bool
    ) -> CGFloat {
        isDirectionInvertedFromDevice ? -rawDelta : rawDelta
    }

    private func visualOffset(
        _ offset: CGFloat,
        for direction: PagingDirection,
        state: State
    ) -> CGFloat {
        let targetPage = state.currentPage + direction.step
        guard targetPage >= 0, targetPage < state.pageCount else {
            return offset * 0.18
        }

        return offset
    }

    private func scheduleDebouncedFinish() {
        finalizeWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.finishGesture(cancelled: false, reason: "debounce")
        }
        finalizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func resetGesture(cancelAnimationDuration: TimeInterval) {
        finalizeWorkItem?.cancel()
        finalizeWorkItem = nil
        activeGesture = nil
        suppressMomentumUntil = 0
        configuration.onCancel(cancelAnimationDuration)
    }
}
