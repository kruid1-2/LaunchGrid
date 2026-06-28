import AppKit
import OSLog
import QuartzCore

@MainActor
final class PagingSurfaceController {
    struct Context {
        let contentView: NSView
        let viewportFrame: CGRect
        let pages: [[AppItem]]
        let currentPage: Int
        let layout: LaunchpadLayout
        let iconCache: IconCache
        let onLaunch: (AppItem) -> Void
    }

    private final class SurfaceContainerView: NSView {
        override var acceptsFirstResponder: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }
    }

    private let logger = Logger(subsystem: "com.launchgrid.app", category: "paging-surface")
    private let signposter = OSSignposter(subsystem: "com.launchgrid.app", category: "paging-surface")
    private let cache = PageSurfaceCache()
    private let containerView = SurfaceContainerView()
    private let transitionView = NSView()
    private let motionDebugLabel = NSTextField(labelWithString: "")
    private var previousSurface = PageSurfaceView()
    private var currentSurface = PageSurfaceView()
    private var nextSurface = PageSurfaceView()
    private lazy var driver = PagingGestureDriver(
        responseTime: motionResponseTime,
        onSample: { [weak self] timestamp, target, displayed in
            self?.recordMotionSample(timestamp: timestamp, target: target, displayed: displayed)
        },
        onFrame: { [weak self] translation in
            self?.applyTranslation(translation)
        }
    )

    private weak var attachedContentView: NSView?
    private var signature: PageSurfaceCache.Signature?
    private var pages: [[AppItem]] = [[]]
    private var layout: LaunchpadLayout?
    private weak var iconCache: IconCache?
    private var onLaunch: ((AppItem) -> Void)?
    private var currentPage = 0
    private var pageWidth: CGFloat = 1
    private var currentTranslation: CGFloat = 0
    private var gestureStartTranslation: CGFloat = 0
    private var isSettling = false
    private var settleGeneration = 0
    private var transitionSessionID: UInt64 = 0
    private var activeDestination: PagingDirection?
    private var activeTransition: ActivePagingTransition?
    private let motionResponseTime: TimeInterval = 0.008
    private let springMass: CGFloat = 1.0
    private let springStiffness: CGFloat = 380
    private let springDamping: CGFloat = 39
    private let minSettleDuration: TimeInterval = 0.12
    private let maxSettleDuration: TimeInterval = 0.24
    private let debugMotionEnabled = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_MOTION"] == "1"
    private let debugSurfaceBordersEnabled = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_SURFACES"] == "1"
    private let debugSurfaceProbeEnabled = ProcessInfo.processInfo.environment["LAUNCHGRID_DEBUG_SURFACE_PROBE"] == "1"
    private var debugSurfaceProbeRan = false
    private var motionSessionID = 0
    private var motionSamples: [MotionSample] = []
    private var settleDebugTimer: Timer?

    private struct MotionSample {
        let timestamp: TimeInterval
        let target: CGFloat
        let displayed: CGFloat
        let velocity: CGFloat
        let currentPage: Int
        let isSettling: Bool
    }

    private struct ActivePagingTransition {
        let sessionID: UInt64
        let direction: PagingDirection
        let sourceSurfaceID: ObjectIdentifier
        let destinationSurfaceID: ObjectIdentifier
        let sourcePageIndex: Int
        let destinationPageIndex: Int

        func contains(_ surface: PageSurfaceView) -> Bool {
            let id = ObjectIdentifier(surface)
            return id == sourceSurfaceID || id == destinationSurfaceID
        }
    }

    private enum SettleCompletion {
        case cancel
        case commit(
            direction: PagingDirection,
            targetPage: Int,
            layout: LaunchpadLayout,
            iconCache: IconCache,
            onLaunch: (AppItem) -> Void,
            commitPage: () -> Void
        )
    }

    init() {
        containerView.identifier = NSUserInterfaceItemIdentifier("LaunchGridPagingSurfaceContainer")
        containerView.wantsLayer = true
        containerView.layer?.masksToBounds = true
        containerView.layer?.zPosition = 900

        transitionView.identifier = NSUserInterfaceItemIdentifier("LaunchGridPagingTransitionContainer")
        transitionView.wantsLayer = true
        transitionView.layer?.masksToBounds = false
        transitionView.layer?.anchorPoint = .zero
        transitionView.layer?.actions = disabledLayerActions
        containerView.addSubview(transitionView)

        for surface in [previousSurface, currentSurface, nextSurface] {
            surface.wantsLayer = true
            surface.layer?.actions = disabledLayerActions
            transitionView.addSubview(surface)
        }

        if debugMotionEnabled {
            motionDebugLabel.identifier = NSUserInterfaceItemIdentifier("LaunchGridMotionDebugLabel")
            motionDebugLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            motionDebugLabel.textColor = .white
            motionDebugLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
            motionDebugLabel.drawsBackground = true
            motionDebugLabel.isBordered = false
            motionDebugLabel.maximumNumberOfLines = 4
            motionDebugLabel.wantsLayer = true
            motionDebugLabel.layer?.cornerRadius = 6
            motionDebugLabel.layer?.masksToBounds = true
            motionDebugLabel.layer?.zPosition = 1_000
            containerView.addSubview(motionDebugLabel)
        }
    }

    func installOrUpdate(context: Context) {
        guard context.pages.count > 0 else {
            return
        }

        let surfaceSignpost = signposter.beginInterval("SurfaceInstallOrUpdate", id: signposter.makeSignpostID())
        defer {
            signposter.endInterval("SurfaceInstallOrUpdate", surfaceSignpost)
        }

        attachedContentView = context.contentView
        pages = context.pages
        layout = context.layout
        iconCache = context.iconCache
        onLaunch = context.onLaunch
        let contextCurrentPage = min(max(context.currentPage, 0), max(context.pages.count - 1, 0))
        if activeTransition == nil && !isSettling {
            currentPage = contextCurrentPage
        }

        configureContainer(context: context)
        driver.start()

        let nextSignature = cache.signature(
            viewportSize: context.viewportFrame.size,
            layout: context.layout,
            pages: context.pages
        )
        guard signature != nextSignature || abs(pageWidth - context.viewportFrame.width) > 0.5 else {
            return
        }

        guard activeTransition == nil && !isSettling else {
            logger.notice(
                "Surface install/update deferred during active transition contextPage=\(contextCurrentPage) currentPage=\(self.currentPage) settling=\(self.isSettling)"
            )
            return
        }

        currentPage = contextCurrentPage
        signature = nextSignature
        configureAllSurfaces(context: context)
        runDebugContinuityProbeIfNeeded()
        logger.notice(
            "Surface installed page=\(self.currentPage) pageCount=\(context.pages.count) pageWidth=\(self.pageWidth) surfaceCount=\(self.transitionView.subviews.count)"
        )
    }

    func beginGesture(context: Context, destination direction: PagingDirection) -> Bool {
        installOrUpdate(context: context)
        guard context.pages.count > 1 else {
            return false
        }

        interruptSettleIfNeeded(reason: "new-gesture")
        let targetPage = currentPage + direction.step
        guard pages.indices.contains(targetPage) else {
            logger.notice(
                "Surface gesture refused boundary page=\(self.currentPage) direction=\(direction.rawValue, privacy: .public)"
            )
            return false
        }

        guard destinationSurfaceIsReady(for: direction) else {
            logger.notice(
                "Surface gesture refused destination not ready page=\(self.currentPage) direction=\(direction.rawValue, privacy: .public) previous=\(self.previousSurface.pageIndex) current=\(self.currentSurface.pageIndex) next=\(self.nextSurface.pageIndex)"
            )
            return false
        }

        beginActiveTransition(direction: direction)
        gestureStartTranslation = currentTranslation
        driver.setTarget(currentTranslation)
        driver.start()
        startMotionSessionIfNeeded()
        logger.notice(
            "Surface gesture began page=\(self.currentPage) destination=\(direction.rawValue, privacy: .public) startTranslation=\(self.currentTranslation)"
        )
        logger.notice(
            "Surface destination ready direction=\(direction.rawValue, privacy: .public) currentFrame=\(self.currentSurface.frame.debugDescription, privacy: .public) destinationFrame=\(self.destinationSurface(for: direction).frame.debugDescription, privacy: .public)"
        )
        return true
    }

    func track(offset: CGFloat) {
        let target = min(pageWidth, max(-pageWidth, gestureStartTranslation + offset))
        driver.setTarget(target)
    }

    func finish(
        direction: PagingDirection,
        duration: TimeInterval,
        releaseVelocity: CGFloat,
        commitPage: @escaping () -> Void
    ) {
        guard let layout, let iconCache, let onLaunch else {
            commitPage()
            return
        }

        let targetPage = min(max(currentPage + direction.step, 0), max(pages.count - 1, 0))
        guard targetPage != currentPage else {
            cancel(duration: duration, releaseVelocity: releaseVelocity)
            return
        }

        let targetTranslation: CGFloat
        switch direction {
        case .next:
            targetTranslation = -pageWidth
        case .previous:
            targetTranslation = pageWidth
        }

        animateToTarget(
            targetTranslation,
            preferredDuration: duration,
            releaseVelocity: releaseVelocity,
            completion: .commit(
                direction: direction,
                targetPage: targetPage,
                layout: layout,
                iconCache: iconCache,
                onLaunch: onLaunch,
                commitPage: commitPage
            )
        )
    }

    func cancel(duration: TimeInterval, releaseVelocity: CGFloat) {
        animateToTarget(
            0,
            preferredDuration: duration,
            releaseVelocity: releaseVelocity,
            completion: .cancel
        )
    }

    func appItem(atWindowPoint point: CGPoint) -> AppItem? {
        // Core Animation moves the transition layer without changing the NSView
        // frames used by AppKit hit testing. Compensate for the visible layer
        // translation before converting the window point into each page view.
        let visibleTranslation = presentationTranslation() ?? currentTranslation
        let untransformedPoint = CGPoint(x: point.x - visibleTranslation, y: point.y)

        for surface in [previousSurface, currentSurface, nextSurface] {
            let localPoint = surface.convert(untransformedPoint, from: nil)
            guard surface.bounds.contains(localPoint),
                  let app = surface.app(atLocalPoint: localPoint) else {
                continue
            }

            return app
        }

        return nil
    }

    func cancelPointerInteraction() {
        previousSurface.cancelPointerInteraction()
        currentSurface.cancelPointerInteraction()
        nextSurface.cancelPointerInteraction()
    }

    func invalidate(reason: StaticString) {
        logger.notice("Surface invalidated reason=\(reason)")
        signature = nil
        settleGeneration += 1
        clearActiveTransition()
        stopSettleDebugSampling()
        transitionView.layer?.removeAllAnimations()
        applyTranslation(0, alignToPixel: true)
        updateDebugSurfaceVisuals()
    }

    func stopAndRelease() {
        driver.stop()
        settleGeneration += 1
        stopSettleDebugSampling()
        transitionView.layer?.removeAllAnimations()
        applyTranslation(0, alignToPixel: true)
        containerView.removeFromSuperview()
        signature = nil
        attachedContentView = nil
        onLaunch = nil
        clearActiveTransition()
        logger.notice("Surface stopped surfaceCount=\(self.transitionView.subviews.count)")
    }

    private func configureContainer(context: Context) {
        context.contentView.wantsLayer = true
        if containerView.superview !== context.contentView {
            containerView.removeFromSuperview()
            context.contentView.addSubview(containerView)
        }

        pageWidth = max(1, context.viewportFrame.width)
        let pageHeight = max(1, context.viewportFrame.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerView.frame = context.viewportFrame.integral
        containerView.layer?.masksToBounds = true
        containerView.layer?.zPosition = 900
        transitionView.frame = CGRect(
            x: -pageWidth,
            y: 0,
            width: pageWidth * 3,
            height: pageHeight
        )
        transitionView.layer?.transform = CATransform3DMakeTranslation(currentTranslation, 0, 0)
        if debugMotionEnabled {
            motionDebugLabel.frame = CGRect(x: 18, y: 18, width: 360, height: 64)
        }
        layoutSurfaceFrames(pageHeight: pageHeight)
        CATransaction.commit()
    }

    private func configureAllSurfaces(context: Context) {
        let generation = cache.nextGeneration()
        configure(
            surface: previousSurface,
            pageIndex: currentPage - 1,
            layout: context.layout,
            iconCache: context.iconCache,
            generation: generation,
            onLaunch: context.onLaunch
        )
        configure(
            surface: currentSurface,
            pageIndex: currentPage,
            layout: context.layout,
            iconCache: context.iconCache,
            generation: generation,
            onLaunch: context.onLaunch
        )
        configure(
            surface: nextSurface,
            pageIndex: currentPage + 1,
            layout: context.layout,
            iconCache: context.iconCache,
            generation: generation,
            onLaunch: context.onLaunch
        )
        preloadFarNeighbors(iconCache: context.iconCache)
        applyTranslation(0, alignToPixel: true)
        clearActiveTransition()
        updateDebugSurfaceVisuals()
    }

    private func beginActiveTransition(direction: PagingDirection) {
        clearActiveTransition()
        transitionSessionID += 1

        let source = currentSurface
        let destination = destinationSurface(for: direction)
        let transition = ActivePagingTransition(
            sessionID: transitionSessionID,
            direction: direction,
            sourceSurfaceID: ObjectIdentifier(source),
            destinationSurfaceID: ObjectIdentifier(destination),
            sourcePageIndex: currentPage,
            destinationPageIndex: currentPage + direction.step
        )

        activeDestination = direction
        activeTransition = transition
        source.setPagingLocked(true)
        destination.setPagingLocked(true)
        updateDebugSurfaceVisuals()
        logger.notice(
            "Surface tracking began session=\(transition.sessionID) sourcePage=\(transition.sourcePageIndex) destinationPage=\(transition.destinationPageIndex) sourceID=\(self.surfaceID(source), privacy: .public) destinationID=\(self.surfaceID(destination), privacy: .public) previous=\(self.surfaceState(self.previousSurface), privacy: .public) current=\(self.surfaceState(self.currentSurface), privacy: .public) next=\(self.surfaceState(self.nextSurface), privacy: .public)"
        )
    }

    private func clearActiveTransition() {
        activeDestination = nil
        activeTransition = nil
        previousSurface.setPagingLocked(false)
        currentSurface.setPagingLocked(false)
        nextSurface.setPagingLocked(false)
        updateDebugSurfaceVisuals()
    }

    private func rotateSlots(direction: PagingDirection) {
        switch direction {
        case .next:
            let oldPrevious = previousSurface
            previousSurface = currentSurface
            currentSurface = nextSurface
            nextSurface = oldPrevious
        case .previous:
            let oldNext = nextSurface
            nextSurface = currentSurface
            currentSurface = previousSurface
            previousSurface = oldNext
        }

        layoutSurfaceFrames(pageHeight: transitionView.bounds.height)
    }

    private func refreshOffscreenSurface(
        after direction: PagingDirection,
        targetPage: Int,
        layout: LaunchpadLayout,
        iconCache: IconCache,
        onLaunch: @escaping (AppItem) -> Void
    ) {
        let refreshStart = ContinuousClock.now
        let surface: PageSurfaceView
        let pageIndex: Int
        let role: String
        switch direction {
        case .next:
            surface = nextSurface
            pageIndex = targetPage + 1
            role = "next"
        case .previous:
            surface = previousSurface
            pageIndex = targetPage - 1
            role = "previous"
        }

        guard canRefreshOffscreen(surface: surface, expectedRole: role) else {
            logger.fault(
                "Surface offscreen refresh rejected role=\(role, privacy: .public) requestedPage=\(pageIndex) state=\(self.surfaceState(surface), privacy: .public) transition=\(self.activeTransitionDescription, privacy: .public)"
            )
            return
        }

        let generation = cache.nextGeneration()
        logger.notice(
            "Surface offscreen refresh began role=\(role, privacy: .public) requestedPage=\(pageIndex) generation=\(generation) state=\(self.surfaceState(surface), privacy: .public)"
        )
        configure(
            surface: surface,
            pageIndex: pageIndex,
            layout: layout,
            iconCache: iconCache,
            generation: generation,
            onLaunch: onLaunch
        )
        let elapsed = milliseconds(refreshStart.duration(to: .now))
        logger.notice(
            "Surface offscreen refresh ended role=\(role, privacy: .public) requestedPage=\(pageIndex) generation=\(generation) ms=\(elapsed, format: .fixed(precision: 2)) previous=\(self.surfaceState(self.previousSurface), privacy: .public) current=\(self.surfaceState(self.currentSurface), privacy: .public) next=\(self.surfaceState(self.nextSurface), privacy: .public)"
        )
    }

    private func preloadFarNeighbors(iconCache: IconCache) {
        let indexes = [currentPage - 2, currentPage + 2]
        let apps = indexes.flatMap { index in
            pages.indices.contains(index) ? pages[index] : []
        }
        iconCache.preloadIcons(for: apps)
    }

    private func configure(
        surface: PageSurfaceView,
        pageIndex: Int,
        layout: LaunchpadLayout,
        iconCache: IconCache,
        generation: Int,
        onLaunch: @escaping (AppItem) -> Void
    ) {
        if surface.isPagingLocked || activeTransition?.contains(surface) == true {
            logger.fault(
                "Visible surface configure blocked role=\(self.roleName(for: surface), privacy: .public) requestedPage=\(pageIndex) currentPage=\(self.currentPage) state=\(self.surfaceState(surface), privacy: .public) transition=\(self.activeTransitionDescription, privacy: .public)"
            )
            return
        }

        if activeDestination != nil, visibleSurfacesForActiveTransition().contains(where: { $0 === surface }) {
            logger.fault(
                "Active visible surface configure blocked role=\(self.roleName(for: surface), privacy: .public) requestedPage=\(pageIndex) currentPage=\(self.currentPage) state=\(self.surfaceState(surface), privacy: .public) transition=\(self.activeTransitionDescription, privacy: .public)"
            )
            return
        }

        let pageApps = pages.indices.contains(pageIndex) ? pages[pageIndex] : []
        surface.configure(
            pageIndex: pageIndex,
            apps: pageApps,
            layout: layout,
            iconCache: iconCache,
            generation: generation,
            onLaunch: onLaunch
        )
        surface.forceRenderIfNeeded()
    }

    private func layoutSurfaceFrames(pageHeight: CGFloat) {
        previousSurface.frame = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        currentSurface.frame = CGRect(x: pageWidth, y: 0, width: pageWidth, height: pageHeight)
        nextSurface.frame = CGRect(x: pageWidth * 2, y: 0, width: pageWidth, height: pageHeight)
        updateDebugSurfaceVisuals()
    }

    private func animateToTarget(
        _ targetTranslation: CGFloat,
        preferredDuration: TimeInterval,
        releaseVelocity: CGFloat,
        completion: SettleCompletion
    ) {
        driver.stop()
        let fromValue = presentationTranslation() ?? driver.currentDisplayed
        guard abs(targetTranslation - fromValue) > 0.5 else {
            completeSettle(completion: completion)
            logger.notice("Surface settle skipped zero-distance target=\(targetTranslation) page=\(self.currentPage)")
            return
        }

        let animationDuration = settleDuration(
            from: fromValue,
            to: targetTranslation,
            releaseVelocity: releaseVelocity,
            fallbackDuration: preferredDuration
        )
        let initialVelocity = springInitialVelocity(
            releaseVelocity: releaseVelocity,
            from: fromValue,
            to: targetTranslation
        )
        settleGeneration += 1
        let settleID = settleGeneration
        isSettling = true
        startSettleDebugSampling(target: targetTranslation)
        logger.notice("Surface settle began target=\(targetTranslation) from=\(fromValue)")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transitionView.layer?.removeAnimation(forKey: "surface-settle")
        transitionView.layer?.transform = CATransform3DMakeTranslation(fromValue, 0, 0)
        CATransaction.commit()

        let animation = CASpringAnimation(keyPath: "transform.translation.x")
        animation.fromValue = fromValue
        animation.toValue = targetTranslation
        animation.mass = springMass
        animation.stiffness = springStiffness
        animation.damping = springDamping
        animation.initialVelocity = initialVelocity

        // Let the spring complete its natural curve instead of truncating it at
        // an arbitrary duration, which caused the visible hard stop at the end.
        // Speed scales the complete critically-damped curve to the desired time.
        let naturalDuration = max(animation.settlingDuration, 0.001)
        animation.duration = naturalDuration
        animation.speed = Float(max(0.1, naturalDuration / animationDuration))
        animation.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.settleGeneration == settleID else {
                return
            }

            self.completeSettle(completion: completion)
        }
        transitionView.layer?.transform = CATransform3DMakeTranslation(targetTranslation, 0, 0)
        transitionView.layer?.add(animation, forKey: "surface-settle")
        CATransaction.commit()
        currentTranslation = targetTranslation
        logger.notice(
            "Surface settle animation from=\(fromValue) to=\(targetTranslation) duration=\(animationDuration) releaseVelocity=\(releaseVelocity) initialVelocity=\(initialVelocity)"
        )
    }

    private func completeSettle(completion: SettleCompletion) {
        stopSettleDebugSampling()
        logger.notice("Surface settle ended page=\(self.currentPage)")
        var offscreenRefresh: (() -> Void)?
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch completion {
        case .cancel:
            setTranslation(0, alignToPixel: true)
            clearActiveTransition()
        case let .commit(direction, targetPage, layout, iconCache, onLaunch, commitPage):
            let rotationStart = ContinuousClock.now
            let centerBefore = centeredSurfaceFrameBeforeRotation(direction: direction)
            let expectedCenterSurface = destinationSurface(for: direction)
            logger.notice(
                "Surface slot rotation began direction=\(direction.rawValue, privacy: .public) targetPage=\(targetPage) previous=\(self.surfaceState(self.previousSurface), privacy: .public) current=\(self.surfaceState(self.currentSurface), privacy: .public) next=\(self.surfaceState(self.nextSurface), privacy: .public)"
            )
            rotateSlots(direction: direction)
            setTranslation(0, alignToPixel: true)
            currentPage = targetPage
            commitPage()
            clearActiveTransition()
            let centerAfter = visibleFrame(surface: currentSurface, translation: 0)
            let continuityError = frameDistance(centerBefore, centerAfter)
            let sameSurface = currentSurface === expectedCenterSurface
            let elapsed = milliseconds(rotationStart.duration(to: .now))
            logger.notice(
                "Surface slots atomically rotated direction=\(direction.rawValue, privacy: .public) currentPage=\(targetPage) sameSurface=\(sameSurface) slotError=\(continuityError, format: .fixed(precision: 3)) ms=\(elapsed, format: .fixed(precision: 2)) surfaceCount=\(self.transitionView.subviews.count)"
            )
            offscreenRefresh = { [weak self] in
                self?.refreshOffscreenSurface(
                    after: direction,
                    targetPage: targetPage,
                    layout: layout,
                    iconCache: iconCache,
                    onLaunch: onLaunch
                )
            }
        }
        CATransaction.commit()
        offscreenRefresh?()
        gestureStartTranslation = 0
        isSettling = false
        driver.reset(to: 0)
        driver.start()
        exportMotionCSVIfNeeded()
        logger.notice("Surface settle complete page=\(self.currentPage) surfaceCount=\(self.transitionView.subviews.count)")
    }

    private func settleDuration(
        from startTranslation: CGFloat,
        to targetTranslation: CGFloat,
        releaseVelocity: CGFloat,
        fallbackDuration: TimeInterval
    ) -> TimeInterval {
        let distance = abs(targetTranslation - startTranslation)
        guard distance > 0.5 else {
            return minSettleDuration
        }

        let normalizedDistance = distance / max(pageWidth, 1)
        let normalizedVelocity = abs(releaseVelocity) / max(pageWidth, 1)
        let distanceDuration = 0.11 + TimeInterval(normalizedDistance) * 0.13
        let velocityDuration: TimeInterval
        if normalizedVelocity > 0.05 {
            velocityDuration = TimeInterval(normalizedDistance / max(normalizedVelocity, 0.05)) + 0.06
        } else {
            velocityDuration = fallbackDuration
        }

        let blended = min(distanceDuration, velocityDuration)
        return min(maxSettleDuration, max(minSettleDuration, blended))
    }

    private func springInitialVelocity(
        releaseVelocity: CGFloat,
        from startTranslation: CGFloat,
        to targetTranslation: CGFloat
    ) -> CGFloat {
        let remainingDistance = targetTranslation - startTranslation
        guard abs(remainingDistance) > 1 else {
            return 0
        }

        let normalized = releaseVelocity / remainingDistance
        return min(18, max(-18, normalized))
    }

    private func interruptSettleIfNeeded(reason: String) {
        guard isSettling else {
            return
        }

        let visibleTranslation = presentationTranslation() ?? currentTranslation
        settleGeneration += 1
        stopSettleDebugSampling()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transitionView.layer?.removeAnimation(forKey: "surface-settle")
        transitionView.layer?.transform = CATransform3DMakeTranslation(visibleTranslation, 0, 0)
        CATransaction.commit()

        currentTranslation = visibleTranslation
        gestureStartTranslation = visibleTranslation
        driver.reset(to: visibleTranslation)
        isSettling = false
        updateDebugSurfaceVisuals()
        logger.notice(
            "Surface settle interrupted reason=\(reason, privacy: .public) visibleTranslation=\(visibleTranslation) page=\(self.currentPage)"
        )
    }

    private func applyTranslation(_ translation: CGFloat, alignToPixel: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setTranslation(translation, alignToPixel: alignToPixel)
        CATransaction.commit()
    }

    private func setTranslation(_ translation: CGFloat, alignToPixel: Bool = false) {
        let value = alignToPixel ? pixelAligned(translation) : translation
        transitionView.layer?.transform = CATransform3DMakeTranslation(value, 0, 0)
        currentTranslation = value
    }

    private func presentationTranslation() -> CGFloat? {
        transitionView.layer?.presentation()?.transform.m41
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = attachedContentView?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return (value * scale).rounded() / max(scale, 1)
    }

    private func startMotionSessionIfNeeded() {
        guard debugMotionEnabled else {
            return
        }

        motionSessionID += 1
        motionSamples.removeAll(keepingCapacity: true)
        logger.notice(
            "Motion debug session=\(self.motionSessionID) responseTime=\(self.motionResponseTime) projectionTime=0.19 springStiffness=\(self.springStiffness) springDamping=\(self.springDamping)"
        )
    }

    private func recordMotionSample(timestamp: TimeInterval, target: CGFloat, displayed: CGFloat) {
        guard debugMotionEnabled else {
            return
        }

        let velocity: CGFloat
        if let previous = motionSamples.last {
            let elapsed = max(0.001, timestamp - previous.timestamp)
            velocity = (displayed - previous.displayed) / CGFloat(elapsed)
        } else {
            velocity = 0
        }

        motionSamples.append(
            MotionSample(
                timestamp: timestamp,
                target: target,
                displayed: displayed,
                velocity: velocity,
                currentPage: currentPage,
                isSettling: isSettling
            )
        )

        motionDebugLabel.stringValue = """
        raw target x: \(String(format: "%.1f", target))
        displayed x: \(String(format: "%.1f", displayed))
        velocity x: \(String(format: "%.1f", velocity))
        page: \(currentPage) state: \(isSettling ? "settling" : "tracking")
        """
    }

    private func startSettleDebugSampling(target: CGFloat) {
        guard debugMotionEnabled else {
            return
        }

        stopSettleDebugSampling()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                let displayed = self.presentationTranslation() ?? self.currentTranslation
                self.recordMotionSample(timestamp: CACurrentMediaTime(), target: target, displayed: displayed)
            }
        }
        settleDebugTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSettleDebugSampling() {
        settleDebugTimer?.invalidate()
        settleDebugTimer = nil
    }

    private func exportMotionCSVIfNeeded() {
        guard debugMotionEnabled, !motionSamples.isEmpty else {
            return
        }

        var csv = "timestamp,targetTranslationX,displayedTranslationX,velocityX,currentPage,isSettling\n"
        for sample in motionSamples {
            csv += "\(sample.timestamp),\(sample.target),\(sample.displayed),\(sample.velocity),\(sample.currentPage),\(sample.isSettling)\n"
        }

        let url = URL(fileURLWithPath: "/private/tmp/launchgrid-motion-\(motionSessionID).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            logger.notice("Motion CSV exported path=\(url.path, privacy: .public)")
        } catch {
            logger.error("Motion CSV export failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    private func destinationSurface(for direction: PagingDirection) -> PageSurfaceView {
        switch direction {
        case .previous:
            previousSurface
        case .next:
            nextSurface
        }
    }

    private func destinationSurfaceIsReady(for direction: PagingDirection) -> Bool {
        let targetPage = currentPage + direction.step
        guard pages.indices.contains(targetPage) else {
            return false
        }

        let surface = destinationSurface(for: direction)
        let expectedAppCount = pages[targetPage].count
        let expectedX = direction == .next ? pageWidth * 2 : 0
        let frameError = abs(surface.frame.minX - expectedX)
            + abs(surface.frame.width - pageWidth)
            + abs(surface.frame.height - transitionView.bounds.height)
        let layerOpacity = surface.layer?.opacity ?? 1
        let ready = surface.pageIndex == targetPage
            && surface.appCount == expectedAppCount
            && surface.hasDrawableContent
            && surface.hasRenderedCurrentGeneration
            && !surface.isHidden
            && surface.alphaValue == 1
            && abs(layerOpacity - 1) < 0.001
            && frameError < 0.5

        logger.notice(
            "Surface destination validation direction=\(direction.rawValue, privacy: .public) ready=\(ready) targetPage=\(targetPage) surfacePage=\(surface.pageIndex) apps=\(surface.appCount) expectedApps=\(expectedAppCount) rendered=\(surface.hasRenderedCurrentGeneration) hidden=\(surface.isHidden) alpha=\(surface.alphaValue) opacity=\(layerOpacity) frameError=\(frameError)"
        )
        return ready
    }

    private func visibleSurfacesForActiveTransition() -> [PageSurfaceView] {
        guard let activeDestination else {
            return []
        }

        switch activeDestination {
        case .next:
            return [currentSurface, nextSurface]
        case .previous:
            return [previousSurface, currentSurface]
        }
    }

    private func canRefreshOffscreen(surface: PageSurfaceView, expectedRole: String) -> Bool {
        guard roleName(for: surface) == expectedRole else {
            return false
        }
        guard activeTransition?.contains(surface) != true, !surface.isPagingLocked else {
            return false
        }

        return isFullyOffscreen(surface: surface)
    }

    private func isFullyOffscreen(surface: PageSurfaceView) -> Bool {
        let frame = visibleFrame(surface: surface, translation: currentTranslation)
        let viewport = containerView.frame
        let tolerance: CGFloat = 0.5
        return frame.maxX <= viewport.minX + tolerance
            || frame.minX >= viewport.maxX - tolerance
    }

    private func updateDebugSurfaceVisuals() {
        guard debugSurfaceBordersEnabled else {
            previousSurface.setDebugBorder(nil)
            currentSurface.setDebugBorder(nil)
            nextSurface.setDebugBorder(nil)
            previousSurface.setDebugOverlay(nil)
            currentSurface.setDebugOverlay(nil)
            nextSurface.setDebugOverlay(nil)
            return
        }

        previousSurface.setDebugBorder(.systemBlue)
        currentSurface.setDebugBorder(.systemRed)
        nextSurface.setDebugBorder(.systemBlue)

        switch activeDestination {
        case .previous:
            previousSurface.setDebugBorder(.systemGreen)
        case .next:
            nextSurface.setDebugBorder(.systemGreen)
        case nil:
            nextSurface.setDebugBorder(.systemGreen)
        }
        previousSurface.setDebugOverlay(debugOverlay(role: "previous", surface: previousSurface))
        currentSurface.setDebugOverlay(debugOverlay(role: "current", surface: currentSurface))
        nextSurface.setDebugOverlay(debugOverlay(role: "next", surface: nextSurface))
    }

    private func debugOverlay(role: String, surface: PageSurfaceView) -> String {
        let readiness = surface.hasDrawableContent ? "ready" : "empty"
        let rendered = surface.hasRenderedCurrentGeneration ? "drawn" : "not-drawn"
        let visibility = isFullyOffscreen(surface: surface) ? "offscreen" : "visible"
        let lock = surface.isPagingLocked ? "locked" : "free"
        let pending = surface.hasPendingDisplayRefresh ? "pending" : "idle"
        return """
        \(role) p=\(surface.pageIndex) \(shortSurfaceID(surface))
        apps=\(surface.appCount) gen=\(surface.generation) \(readiness) \(rendered)
        \(lock) \(visibility) reload=\(pending)
        """
    }

    private func roleName(for surface: PageSurfaceView) -> String {
        if surface === previousSurface {
            return "previous"
        }
        if surface === currentSurface {
            return "current"
        }
        if surface === nextSurface {
            return "next"
        }
        return "unknown"
    }

    private func centeredSurfaceFrameBeforeRotation(direction: PagingDirection) -> CGRect {
        let targetTranslation: CGFloat = direction == .next ? -pageWidth : pageWidth
        return visibleFrame(surface: destinationSurface(for: direction), translation: targetTranslation)
    }

    private func visibleFrame(surface: PageSurfaceView, translation: CGFloat) -> CGRect {
        surface.frame.offsetBy(
            dx: containerView.frame.minX + transitionView.frame.minX + translation,
            dy: containerView.frame.minY
        )
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        max(
            abs(lhs.minX - rhs.minX),
            abs(lhs.minY - rhs.minY),
            abs(lhs.width - rhs.width),
            abs(lhs.height - rhs.height)
        )
    }

    private func runDebugContinuityProbeIfNeeded() {
        guard debugSurfaceProbeEnabled, !debugSurfaceProbeRan, pages.count > 1 else {
            return
        }

        debugSurfaceProbeRan = true
        logger.notice(
            "Surface continuity probe started currentPage=\(self.currentPage) previousID=\(self.surfaceID(self.previousSurface), privacy: .public) currentID=\(self.surfaceID(self.currentSurface), privacy: .public) nextID=\(self.surfaceID(self.nextSurface), privacy: .public)"
        )

        for direction in [PagingDirection.next, .previous] {
            guard destinationSurfaceIsReady(for: direction) else {
                logger.notice(
                    "Surface continuity probe skipped direction=\(direction.rawValue, privacy: .public) currentPage=\(self.currentPage)"
                )
                continue
            }

            activeDestination = direction
            updateDebugSurfaceVisuals()
            let destination = destinationSurface(for: direction)
            let ratios: [CGFloat] = [0.25, 0.5, 0.75]
            for ratio in ratios {
                let translation = (direction == .next ? -pageWidth : pageWidth) * ratio
                let currentFrame = visibleFrame(surface: currentSurface, translation: translation)
                let destinationFrame = visibleFrame(surface: destination, translation: translation)
                let gap = continuityGap(
                    currentFrame: currentFrame,
                    destinationFrame: destinationFrame,
                    direction: direction
                )
                let currentOpacity = currentSurface.layer?.opacity ?? 1
                let destinationOpacity = destination.layer?.opacity ?? 1
                logger.notice(
                    "Surface continuity probe direction=\(direction.rawValue, privacy: .public) ratio=\(ratio, format: .fixed(precision: 2)) gap=\(gap, format: .fixed(precision: 3)) currentPageIndex=\(self.currentSurface.pageIndex) destinationPageIndex=\(destination.pageIndex) currentHidden=\(self.currentSurface.isHidden) destinationHidden=\(destination.isHidden) currentOpacity=\(currentOpacity) destinationOpacity=\(destinationOpacity) currentID=\(self.surfaceID(self.currentSurface), privacy: .public) destinationID=\(self.surfaceID(destination), privacy: .public)"
                )
            }
            activeDestination = nil
            updateDebugSurfaceVisuals()
        }

        logger.notice(
            "Surface continuity probe completed previousID=\(self.surfaceID(self.previousSurface), privacy: .public) currentID=\(self.surfaceID(self.currentSurface), privacy: .public) nextID=\(self.surfaceID(self.nextSurface), privacy: .public)"
        )
    }

    private func continuityGap(
        currentFrame: CGRect,
        destinationFrame: CGRect,
        direction: PagingDirection
    ) -> CGFloat {
        switch direction {
        case .next:
            destinationFrame.minX - currentFrame.maxX
        case .previous:
            currentFrame.minX - destinationFrame.maxX
        }
    }

    private func surfaceID(_ surface: PageSurfaceView) -> String {
        String(describing: ObjectIdentifier(surface))
    }

    private func shortSurfaceID(_ surface: PageSurfaceView) -> String {
        let id = surfaceID(surface)
        return String(id.suffix(8))
    }

    private var activeTransitionDescription: String {
        guard let transition = activeTransition else {
            return "none"
        }

        return "session=\(transition.sessionID) direction=\(transition.direction.rawValue) sourcePage=\(transition.sourcePageIndex) destinationPage=\(transition.destinationPageIndex) sourceID=\(transition.sourceSurfaceID) destinationID=\(transition.destinationSurfaceID)"
    }

    private func surfaceState(_ surface: PageSurfaceView) -> String {
        let opacity = surface.layer?.opacity ?? 1
        let visibility = isFullyOffscreen(surface: surface) ? "offscreen" : "visible"
        return "role=\(roleName(for: surface)) id=\(surfaceID(surface)) page=\(surface.pageIndex) apps=\(surface.appCount) gen=\(surface.generation) rendered=\(surface.hasRenderedCurrentGeneration) frame=\(surface.frame.debugDescription) hidden=\(surface.isHidden) alpha=\(surface.alphaValue) opacity=\(opacity) \(visibility) locked=\(surface.isPagingLocked) pendingDisplay=\(surface.hasPendingDisplayRefresh)"
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private var disabledLayerActions: [String: CAAction] {
        [
            "bounds": NSNull(),
            "contents": NSNull(),
            "frame": NSNull(),
            "opacity": NSNull(),
            "position": NSNull(),
            "transform": NSNull()
        ]
    }
}
