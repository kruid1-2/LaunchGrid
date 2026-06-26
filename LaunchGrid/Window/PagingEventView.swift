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
        let onBegin: (State, PagingDirection) -> Bool
        let onTrackOffset: (CGFloat) -> Void
        let onCommit: (PagingDirection, TimeInterval, CGFloat) -> Void
        let onCancel: (TimeInterval, CGFloat) -> Void

        static let empty = Configuration(
            state: { .empty },
            onBegin: { _, _ in false },
            onTrackOffset: { _ in },
            onCommit: { _, _, _ in },
            onCancel: { _, _ in }
        )
    }

    private struct MotionSample {
        let time: TimeInterval
        let offset: CGFloat
    }

    private struct ScrollGesture {
        let state: State
        var accumulatedOffset: CGFloat
        var samples: [MotionSample] = []
    }

    var configuration = Configuration.empty

    private let logger = Logger(subsystem: "com.launchgrid.app", category: "paging")
    private let motionLogger = Logger(subsystem: "com.launchgrid.app", category: "paging-motion")
    private weak var window: NSWindow?
    private var activeGesture: ScrollGesture?
    private var finalizeWorkItem: DispatchWorkItem?
    private var suppressMomentumUntil: TimeInterval = 0
    private var gestureSequenceID = 0
    private var pendingStartupOffset: CGFloat = 0
    private var debugInputSampleCounter = 0

    // Coalesce high-frequency trackpad events to at most one SwiftUI state
    // update per main-loop turn. This avoids rebuilding all visible pages for
    // every raw delta sample.
    private var pendingTrackOffset: CGFloat?
    private var trackUpdateScheduled = false

    private let scrollResponseMultiplier: CGFloat = 1.0
    private let horizontalDominanceRatio: CGFloat = 1.02
    private let debounceInterval: TimeInterval = 0.14
    private let momentumSuppressionInterval: TimeInterval = 0.08
    private let velocitySampleWindow: TimeInterval = 0.12
    private let velocityCommitThreshold: CGFloat = 920
    private let minimumVelocityCommitDistance: CGFloat = 24
    private let projectionTime: CGFloat = 0.19
    private let projectedCommitRatio: CGFloat = 0.32
    private let distanceCommitRatio: CGFloat = 0.35
    private let directionRecognitionDelta: CGFloat = 0.08
    private let debugMotionEnabled = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_MOTION"] == "1"

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

        // LauncherPanel.sendEvent already guarantees that this input came
        // through the launcher panel. Gesture events can briefly report a nil
        // event.window, so an identity check here incorrectly rejects blank-area
        // gestures. Use the actual pointer location instead.
        guard window.frame.contains(NSEvent.mouseLocation) else {
            return false
        }

        let beginsNewGesture = event.phase.contains(.began)
        if beginsNewGesture {
            finalizeWorkItem?.cancel()
            finalizeWorkItem = nil
            activeGesture = nil
            pendingTrackOffset = nil
            pendingStartupOffset = 0
            suppressMomentumUntil = 0
            logger.notice("Scroll paging new began resets old momentum lock")
        }

        if event.momentumPhase != [], !beginsNewGesture {
            if activeGesture != nil {
                finishGesture(cancelled: false, reason: "momentum")
            }
            let isOldMomentum = ProcessInfo.processInfo.systemUptime < suppressMomentumUntil
            if isOldMomentum {
                logger.notice("Scroll paging ignored old momentum until=\(self.suppressMomentumUntil)")
            }
            return isOldMomentum
        }

        let state = configuration.state()
        guard state.pageCount > 1 else {
            return false
        }
        if state.isTransitioning {
            logger.notice("Scroll paging began while render transition is still settling")
        }

        let pageDeltaX = normalizedPageDelta(
            rawDelta: event.scrollingDeltaX,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
        )
        let pageDeltaY = normalizedPageDelta(
            rawDelta: event.scrollingDeltaY,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice
        )

        if activeGesture == nil {
            guard canStartScrollPaging(pageDeltaX: pageDeltaX, pageDeltaY: pageDeltaY) else {
                rememberStartupOffsetIfHorizontal(pageDeltaX: pageDeltaX, pageDeltaY: pageDeltaY)
                return false
            }

            let startupOffset = pendingStartupOffset + pageDeltaX
            pendingStartupOffset = 0
            let initialDirection = direction(for: startupOffset)
            guard beginGesture(state: state, event: event, direction: initialDirection) else {
                return false
            }
            applyScrollDelta(startupOffset, state: state, rawDelta: pageDeltaX, phase: "began")
        } else {
            applyScrollDelta(pageDeltaX, state: state, rawDelta: pageDeltaX, phase: "changed")
        }

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            finishGesture(cancelled: event.phase.contains(.cancelled), reason: "phase")
        } else {
            scheduleDebouncedFinish()
        }

        return true
    }

    /// Handles AppKit swipe events as a fallback for systems/settings that
    /// promote a horizontal trackpad movement to NSEvent.EventType.swipe rather
    /// than leaving it as scrollWheel events over non-scrollable blank areas.
    func handleSwipe(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible, NSApp.isActive else {
            return false
        }

        guard window.frame.contains(NSEvent.mouseLocation) else {
            return false
        }

        let state = configuration.state()
        guard state.pageCount > 1 else {
            return false
        }
        if state.isTransitioning {
            logger.notice("Swipe paging began while render transition is still settling")
        }

        let pageDeltaX = normalizedPageDelta(
            rawDelta: event.deltaX,
            isDirectionInvertedFromDevice: false
        )
        guard abs(pageDeltaX) > 0.01 else {
            return false
        }

        let direction = direction(for: pageDeltaX)
        let targetPage = state.currentPage + direction.step
        guard targetPage >= 0, targetPage < state.pageCount else {
            configuration.onCancel(state.animationDuration, 0)
            return true
        }

        guard configuration.onBegin(state, direction) else {
            return false
        }
        configuration.onCommit(direction, state.animationDuration, direction == .next ? -state.pageWidth * 4 : state.pageWidth * 4)
        return true
    }

    private func beginGesture(state: State, event: NSEvent, direction: PagingDirection) -> Bool {
        finalizeWorkItem?.cancel()
        guard configuration.onBegin(state, direction) else {
            logger.notice(
                "Scroll paging begin rejected page=\(state.currentPage) direction=\(direction.rawValue, privacy: .public)"
            )
            return false
        }

        gestureSequenceID += 1
        activeGesture = ScrollGesture(
            state: state,
            accumulatedOffset: 0,
            samples: [MotionSample(time: ProcessInfo.processInfo.systemUptime, offset: 0)]
        )
        logger.notice(
            "Scroll paging began session=\(self.gestureSequenceID) page=\(state.currentPage) direction=\(direction.rawValue, privacy: .public) inverted=\(event.isDirectionInvertedFromDevice)"
        )
        return true
    }

    private func applyScrollDelta(
        _ pageDeltaX: CGFloat,
        state: State,
        rawDelta: CGFloat,
        phase: String
    ) {
        guard var gesture = activeGesture else {
            return
        }

        gesture.accumulatedOffset += pageDeltaX * scrollResponseMultiplier
        gesture.accumulatedOffset = min(
            state.pageWidth * 0.96,
            max(-state.pageWidth * 0.96, gesture.accumulatedOffset)
        )
        activeGesture = gesture

        let direction = direction(for: gesture.accumulatedOffset)
        let boundedOffset = visualOffset(gesture.accumulatedOffset, for: direction, state: gesture.state)
        recordMotionSample(offset: boundedOffset, gesture: &gesture)
        activeGesture = gesture
        logInputSampleIfNeeded(
            rawDelta: rawDelta,
            accumulatedOffset: gesture.accumulatedOffset,
            targetOffset: boundedOffset,
            phase: phase,
            state: gesture.state
        )
        configuration.onTrackOffset(boundedOffset)
    }

    private func rememberStartupOffsetIfHorizontal(pageDeltaX: CGFloat, pageDeltaY: CGFloat) {
        guard abs(pageDeltaX) > directionRecognitionDelta,
              abs(pageDeltaX) >= abs(pageDeltaY) * horizontalDominanceRatio else {
            pendingStartupOffset = 0
            return
        }

        pendingStartupOffset += pageDeltaX * scrollResponseMultiplier
        pendingStartupOffset = min(64, max(-64, pendingStartupOffset))
    }

    private func recordMotionSample(offset: CGFloat, gesture: inout ScrollGesture) {
        let now = ProcessInfo.processInfo.systemUptime
        gesture.samples.append(MotionSample(time: now, offset: offset))
        gesture.samples.removeAll { now - $0.time > velocitySampleWindow }
    }

    private func scheduleTrackOffset(_ offset: CGFloat) {
        pendingTrackOffset = offset
        guard !trackUpdateScheduled else {
            return
        }

        trackUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.trackUpdateScheduled = false
            guard let nextOffset = self.pendingTrackOffset else {
                return
            }

            self.pendingTrackOffset = nil
            self.configuration.onTrackOffset(nextOffset)
        }
    }

    private func finishGesture(cancelled: Bool, reason: StaticString) {
        finalizeWorkItem?.cancel()
        finalizeWorkItem = nil

        guard let gesture = activeGesture else {
            return
        }

        activeGesture = nil
        pendingTrackOffset = nil
        suppressMomentumUntil = ProcessInfo.processInfo.systemUptime + momentumSuppressionInterval

        let releaseVelocity = releaseVelocity(for: gesture)
        let projectedOffset = gesture.accumulatedOffset + releaseVelocity * projectionTime
        let decisionOffset = abs(projectedOffset) >= abs(gesture.accumulatedOffset)
            ? projectedOffset
            : gesture.accumulatedOffset
        let direction = direction(for: decisionOffset)
        let sameDirectionVelocity = releaseVelocity * decisionOffset > 0
        let velocityCommit = sameDirectionVelocity
            && abs(releaseVelocity) >= velocityCommitThreshold
            && abs(gesture.accumulatedOffset) >= minimumVelocityCommitDistance
        let projectedCommit = abs(projectedOffset) >= gesture.state.pageWidth * projectedCommitRatio
        let distanceCommit = abs(gesture.accumulatedOffset) >= gesture.state.pageWidth * distanceCommitRatio
        let shouldCommit = !cancelled && (projectedCommit || distanceCommit || velocityCommit)

        guard shouldCommit else {
            logger.notice(
                "Scroll paging cancelled page=\(gesture.state.currentPage) reason=\(reason) offset=\(gesture.accumulatedOffset) projected=\(projectedOffset) velocity=\(releaseVelocity)"
            )
            configuration.onCancel(gesture.state.animationDuration, releaseVelocity)
            return
        }

        let targetPage = gesture.state.currentPage + direction.step
        guard targetPage >= 0, targetPage < gesture.state.pageCount else {
            logger.notice(
                "Scroll paging boundary page=\(gesture.state.currentPage) direction=\(direction.rawValue, privacy: .public)"
            )
            configuration.onCancel(gesture.state.animationDuration, releaseVelocity)
            return
        }

        logger.notice(
            "Scroll paging commit session=\(self.gestureSequenceID) direction=\(direction.rawValue, privacy: .public) from=\(gesture.state.currentPage) to=\(targetPage) offset=\(gesture.accumulatedOffset) projected=\(projectedOffset) velocity=\(releaseVelocity) momentumSuppress=\(self.momentumSuppressionInterval)"
        )
        configuration.onCommit(direction, gesture.state.animationDuration, releaseVelocity)
    }

    private func releaseVelocity(for gesture: ScrollGesture) -> CGFloat {
        guard gesture.samples.count >= 2,
              let first = gesture.samples.first,
              let last = gesture.samples.last else {
            return 0
        }

        let elapsed = max(0.001, last.time - first.time)
        let rawVelocity = (last.offset - first.offset) / CGFloat(elapsed)
        guard rawVelocity.isFinite else {
            return 0
        }

        let maxVelocity = gesture.state.pageWidth * 6
        let clampedVelocity = min(maxVelocity, max(-maxVelocity, rawVelocity))
        if clampedVelocity * gesture.accumulatedOffset < 0, abs(clampedVelocity) > 180 {
            return 0
        }

        return clampedVelocity
    }

    private func canStartScrollPaging(pageDeltaX: CGFloat, pageDeltaY: CGFloat) -> Bool {
        let absX = abs(pageDeltaX)
        let absY = abs(pageDeltaY)
        return absX > max(directionRecognitionDelta, absY * horizontalDominanceRatio)
    }

    private func direction(for offset: CGFloat) -> PagingDirection {
        offset < 0 ? .next : .previous
    }

    private func normalizedPageDelta(
        rawDelta: CGFloat,
        isDirectionInvertedFromDevice: Bool
    ) -> CGFloat {
        // AppKit's signed horizontal delta already matches the visual page
        // movement we need here: negative reveals the next page, positive
        // reveals the previous page. Applying isDirectionInvertedFromDevice
        // again reverses natural-scrolling trackpads.
        rawDelta
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
        pendingTrackOffset = nil
        trackUpdateScheduled = false
        pendingStartupOffset = 0
        suppressMomentumUntil = 0
        configuration.onCancel(cancelAnimationDuration, 0)
    }

    private func logInputSampleIfNeeded(
        rawDelta: CGFloat,
        accumulatedOffset: CGFloat,
        targetOffset: CGFloat,
        phase: String,
        state: State
    ) {
        guard debugMotionEnabled else {
            return
        }

        debugInputSampleCounter += 1
        guard debugInputSampleCounter == 1 || debugInputSampleCounter.isMultiple(of: 4) else {
            return
        }

        motionLogger.notice(
            "input t=\(ProcessInfo.processInfo.systemUptime) phase=\(phase) rawDelta=\(rawDelta) accumulated=\(accumulatedOffset) target=\(targetOffset) page=\(state.currentPage)"
        )
    }
}
