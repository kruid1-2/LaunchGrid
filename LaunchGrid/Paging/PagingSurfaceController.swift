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
    private let snapshotCache = PageSnapshotCache()
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
    private var activeSettleCompletion: SettleCompletion?
    private var transitionSessionID: UInt64 = 0
    private var offscreenRefreshToken: UInt64 = 0
    private var scheduledOffscreenRefresh: DispatchWorkItem?
    private var snapshotPrewarmToken: UInt64 = 0
    private var scheduledSnapshotPrewarm: DispatchWorkItem?
    private var queuedPrewarmKeys: Set<PageSnapshotCache.Key> = []
    private var prewarmQueue: [SnapshotPrewarmTask] = []
    private var isPrewarmRendering = false
    private var lastUserInputTime: TimeInterval = 0
    private var lastPrewarmEndTime: TimeInterval = 0
    private var lastPrewarmDuration: TimeInterval = 0
    private var controllerGeneration: UInt64 = 0
    private var activeDestination: PagingDirection?
    private var activeTransition: ActivePagingTransition?
    private let motionResponseTime: TimeInterval = 0.008
    private let springMass: CGFloat = 1.0
    private let springStiffness: CGFloat = 380
    private let springDamping: CGFloat = 39
    private let minSettleDuration: TimeInterval = 0.12
    private let maxSettleDuration: TimeInterval = 0.24
    private let offscreenRefreshDelay: TimeInterval = 0.05
    private let prewarmIdleWindow: TimeInterval = 0.20
    private let prewarmMinimumGap: TimeInterval = 0.16
    private let prewarmLongRenderGap: TimeInterval = 0.35
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

    private struct OffscreenRefreshRequest {
        var token: UInt64
        let direction: PagingDirection
        let targetPage: Int
        let requestedPage: Int
        let expectedRole: String
        let layout: LaunchpadLayout
        let iconCache: IconCache
        let onLaunch: (AppItem) -> Void
    }

    private enum SnapshotPrewarmPriority: Int, Comparable, CustomStringConvertible {
        case adjacentPrimary = 0
        case adjacentSecondary = 1
        case farDirection = 2
        case longIdle = 3

        static func < (lhs: SnapshotPrewarmPriority, rhs: SnapshotPrewarmPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var description: String {
            switch self {
            case .adjacentPrimary:
                "adjacent-primary"
            case .adjacentSecondary:
                "adjacent-secondary"
            case .farDirection:
                "far-direction"
            case .longIdle:
                "long-idle"
            }
        }
    }

    private struct SnapshotPrewarmTask {
        let token: UInt64
        let controllerGeneration: UInt64
        let pageIndex: Int
        let restorePageIndex: Int?
        let role: String
        let key: PageSnapshotCache.Key
        let priority: SnapshotPrewarmPriority
        let scheduledAt: TimeInterval
        let layout: LaunchpadLayout
        let iconCache: IconCache
        let onLaunch: (AppItem) -> Void
        let reason: String
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
            surface.onCacheableSnapshotRendered = { [weak self] surface, snapshot in
                self?.insertRenderedSnapshot(
                    surface: surface,
                    snapshot: snapshot,
                    reason: "surface-render-callback"
                )
            }
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
        if signature != nil {
            snapshotCache.removeAll()
            cancelSnapshotPrewarmQueue(reason: "surface-signature-changed")
            logger.notice("Snapshot cache invalidated reason=surface-signature-changed")
        }
        controllerGeneration += 1
        let installTime = ProcessInfo.processInfo.systemUptime
        lastUserInputTime = installTime
        lastPrewarmEndTime = installTime
        lastPrewarmDuration = 0
        signature = nextSignature
        configureAllSurfaces(context: context)
        enqueueStartupPrewarm(layout: context.layout, iconCache: context.iconCache, onLaunch: context.onLaunch, reason: "install")
        runDebugContinuityProbeIfNeeded()
        logger.notice(
            "Surface installed page=\(self.currentPage) pageCount=\(context.pages.count) pageWidth=\(self.pageWidth) surfaceCount=\(self.transitionView.subviews.count)"
        )
    }

    func beginGesture(context: Context, destination direction: PagingDirection) -> Bool {
        markUserInteraction(reason: "begin-gesture")
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
        markUserInteraction(reason: "track")
        let target = min(pageWidth, max(-pageWidth, gestureStartTranslation + offset))
        driver.setTarget(target)
    }

    func finish(
        direction: PagingDirection,
        duration: TimeInterval,
        releaseVelocity: CGFloat,
        commitPage: @escaping () -> Void
    ) {
        markUserInteraction(reason: "finish")
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
        markUserInteraction(reason: "cancel")
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
        activeSettleCompletion = nil
        cancelScheduledOffscreenRefresh(reason: "invalidate")
        cancelSnapshotPrewarmQueue(reason: "invalidate")
        controllerGeneration += 1
        clearActiveTransition()
        stopSettleDebugSampling()
        transitionView.layer?.removeAllAnimations()
        applyTranslation(0, alignToPixel: true)
        updateDebugSurfaceVisuals()
    }

    func stopAndRelease() {
        driver.stop()
        settleGeneration += 1
        activeSettleCompletion = nil
        cancelScheduledOffscreenRefresh(reason: "stop")
        cancelSnapshotPrewarmQueue(reason: "stop")
        controllerGeneration += 1
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
            onLaunch: context.onLaunch,
            reason: "configure-all-previous",
            renderImmediately: false
        )
        configure(
            surface: currentSurface,
            pageIndex: currentPage,
            layout: context.layout,
            iconCache: context.iconCache,
            generation: generation,
            onLaunch: context.onLaunch,
            reason: "configure-all-current",
            renderImmediately: true
        )
        configure(
            surface: nextSurface,
            pageIndex: currentPage + 1,
            layout: context.layout,
            iconCache: context.iconCache,
            generation: generation,
            onLaunch: context.onLaunch,
            reason: "configure-all-next",
            renderImmediately: false
        )
        preloadFarNeighbors(iconCache: context.iconCache)
        applyTranslation(0, alignToPixel: true)
        clearActiveTransition()
        updateDebugSurfaceVisuals()
    }

    private func beginActiveTransition(direction: PagingDirection) {
        clearActiveTransition()
        cancelScheduledOffscreenRefresh(reason: "begin-transition")
        cancelSnapshotPrewarmQueue(reason: "begin-transition")
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
        onLaunch: @escaping (AppItem) -> Void,
        token: UInt64
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
                "Surface offscreen refresh rejected token=\(token) role=\(role, privacy: .public) requestedPage=\(pageIndex) state=\(self.surfaceState(surface), privacy: .public) transition=\(self.activeTransitionDescription, privacy: .public)"
            )
            return
        }

        let generation = cache.nextGeneration()
        logger.notice(
            "Surface offscreen refresh began token=\(token) role=\(role, privacy: .public) requestedPage=\(pageIndex) generation=\(generation) state=\(self.surfaceState(surface), privacy: .public)"
        )
        configure(
            surface: surface,
            pageIndex: pageIndex,
            layout: layout,
            iconCache: iconCache,
            generation: generation,
            onLaunch: onLaunch,
            reason: "offscreen-refresh"
        )
        let elapsed = milliseconds(refreshStart.duration(to: .now))
        logger.notice(
            "Surface offscreen refresh ended token=\(token) role=\(role, privacy: .public) requestedPage=\(pageIndex) generation=\(generation) ms=\(elapsed, format: .fixed(precision: 2)) previous=\(self.surfaceState(self.previousSurface), privacy: .public) current=\(self.surfaceState(self.currentSurface), privacy: .public) next=\(self.surfaceState(self.nextSurface), privacy: .public)"
        )
    }

    private func scheduleOffscreenRefresh(_ request: OffscreenRefreshRequest) {
        if scheduledOffscreenRefresh != nil {
            scheduledOffscreenRefresh?.cancel()
            logger.notice(
                "Surface offscreen refresh coalesced previousToken=\(self.offscreenRefreshToken) newDirection=\(request.direction.rawValue, privacy: .public) newPage=\(request.requestedPage)"
            )
        }

        offscreenRefreshToken += 1
        var request = request
        request.token = offscreenRefreshToken
        let token = request.token
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.performScheduledOffscreenRefresh(request)
            }
        }
        scheduledOffscreenRefresh = workItem
        logger.notice(
            "Surface offscreen refresh scheduled token=\(token) role=\(request.expectedRole, privacy: .public) requestedPage=\(request.requestedPage) targetPage=\(request.targetPage) delay=\(self.offscreenRefreshDelay)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + offscreenRefreshDelay, execute: workItem)
    }

    private func cancelScheduledOffscreenRefresh(reason: String) {
        guard scheduledOffscreenRefresh != nil else {
            return
        }

        scheduledOffscreenRefresh?.cancel()
        scheduledOffscreenRefresh = nil
        offscreenRefreshToken += 1
        logger.notice(
            "Surface offscreen refresh canceled reason=\(reason, privacy: .public) token=\(self.offscreenRefreshToken)"
        )
    }

    private func markUserInteraction(reason: String) {
        lastUserInputTime = ProcessInfo.processInfo.systemUptime
        cancelSnapshotPrewarmQueue(reason: "interaction-\(reason)")
    }

    private func cancelSnapshotPrewarmQueue(reason: String) {
        let pendingCount = prewarmQueue.count
        let hadScheduledWork = scheduledSnapshotPrewarm != nil
        scheduledSnapshotPrewarm?.cancel()
        scheduledSnapshotPrewarm = nil
        prewarmQueue.removeAll(keepingCapacity: true)
        queuedPrewarmKeys.removeAll(keepingCapacity: true)
        snapshotPrewarmToken += 1
        if hadScheduledWork || pendingCount > 0 || isPrewarmRendering {
            logger.notice(
                "Snapshot prewarm canceled reason=\(reason, privacy: .public) token=\(self.snapshotPrewarmToken) pending=\(pendingCount) rendering=\(self.isPrewarmRendering)"
            )
        }
    }

    private func enqueueStartupPrewarm(
        layout: LaunchpadLayout,
        iconCache: IconCache,
        onLaunch: @escaping (AppItem) -> Void,
        reason: String
    ) {
        guard !debugSurfaceBordersEnabled else {
            logger.notice("Snapshot prewarm skipped reason=debug-surfaces-enabled")
            return
        }

        insertRenderedSnapshotIfPossible(surface: previousSurface, layout: layout, iconCache: iconCache, reason: "prewarm-existing-previous")
        insertRenderedSnapshotIfPossible(surface: currentSurface, layout: layout, iconCache: iconCache, reason: "prewarm-existing-current")
        insertRenderedSnapshotIfPossible(surface: nextSurface, layout: layout, iconCache: iconCache, reason: "prewarm-existing-next")

        if pages.indices.contains(currentPage + 1) {
            enqueueSnapshotPrewarm(
                pageIndex: currentPage + 1,
                restorePageIndex: nil,
                role: "next",
                priority: .adjacentPrimary,
                layout: layout,
                iconCache: iconCache,
                onLaunch: onLaunch,
                reason: "\(reason)-adjacent-next"
            )
        }

        if pages.indices.contains(currentPage - 1) {
            enqueueSnapshotPrewarm(
                pageIndex: currentPage - 1,
                restorePageIndex: nil,
                role: "previous",
                priority: .adjacentSecondary,
                layout: layout,
                iconCache: iconCache,
                onLaunch: onLaunch,
                reason: "\(reason)-adjacent-previous"
            )
        }

        if currentPage == 0, pages.indices.contains(2) {
            enqueueSnapshotPrewarm(
                pageIndex: 2,
                restorePageIndex: nil,
                role: "previous",
                priority: .farDirection,
                layout: layout,
                iconCache: iconCache,
                onLaunch: onLaunch,
                reason: "\(reason)-forward-spare-2"
            )
            if pages.indices.contains(3) {
                enqueueSnapshotPrewarm(
                    pageIndex: 3,
                    restorePageIndex: 2,
                    role: "previous",
                    priority: .longIdle,
                    layout: layout,
                    iconCache: iconCache,
                    onLaunch: onLaunch,
                    reason: "\(reason)-forward-spare-3"
                )
            }
        } else if currentPage == pages.count - 1, pages.indices.contains(currentPage - 2) {
            enqueueSnapshotPrewarm(
                pageIndex: currentPage - 2,
                restorePageIndex: nil,
                role: "next",
                priority: .farDirection,
                layout: layout,
                iconCache: iconCache,
                onLaunch: onLaunch,
                reason: "\(reason)-backward-spare-2"
            )
            if pages.indices.contains(currentPage - 3) {
                enqueueSnapshotPrewarm(
                    pageIndex: currentPage - 3,
                    restorePageIndex: currentPage - 2,
                    role: "next",
                    priority: .longIdle,
                    layout: layout,
                    iconCache: iconCache,
                    onLaunch: onLaunch,
                    reason: "\(reason)-backward-spare-3"
                )
            }
        }

        scheduleNextSnapshotPrewarm(reason: reason)
    }

    private func enqueueSnapshotPrewarm(
        pageIndex: Int,
        restorePageIndex: Int?,
        role: String,
        priority: SnapshotPrewarmPriority,
        layout: LaunchpadLayout,
        iconCache: IconCache,
        onLaunch: @escaping (AppItem) -> Void,
        reason: String
    ) {
        guard pages.indices.contains(pageIndex) else {
            return
        }

        let surface = surface(forRole: role)
        guard let key = makeSnapshotKey(
            pageIndex: pageIndex,
            apps: pageApps(for: pageIndex),
            layout: layout,
            surface: surface,
            iconCache: iconCache
        ) else {
            logger.notice("Snapshot prewarm skipped reason=\(reason, privacy: .public) page=\(pageIndex) priority=\(priority.description, privacy: .public) cause=no-key")
            return
        }

        if snapshotCache.entry(for: key) != nil {
            logger.notice("Snapshot prewarm skipped due to cache hit reason=\(reason, privacy: .public) key=\(key.description, privacy: .public) priority=\(priority.description, privacy: .public)")
            return
        }

        guard queuedPrewarmKeys.insert(key).inserted else {
            logger.notice("Snapshot prewarm skipped duplicate reason=\(reason, privacy: .public) key=\(key.description, privacy: .public) priority=\(priority.description, privacy: .public)")
            return
        }

        let task = SnapshotPrewarmTask(
            token: snapshotPrewarmToken,
            controllerGeneration: controllerGeneration,
            pageIndex: pageIndex,
            restorePageIndex: restorePageIndex,
            role: role,
            key: key,
            priority: priority,
            scheduledAt: ProcessInfo.processInfo.systemUptime,
            layout: layout,
            iconCache: iconCache,
            onLaunch: onLaunch,
            reason: reason
        )
        prewarmQueue.append(task)
        prewarmQueue.sort { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.scheduledAt < rhs.scheduledAt
            }
            return lhs.priority < rhs.priority
        }
        logger.notice(
            "Snapshot prewarm enqueued reason=\(reason, privacy: .public) token=\(task.token) page=\(pageIndex) restore=\(restorePageIndex ?? -1) role=\(role, privacy: .public) priority=\(priority.description, privacy: .public) key=\(key.description, privacy: .public) pending=\(self.prewarmQueue.count)"
        )
    }

    private func scheduleNextSnapshotPrewarm(reason: String) {
        guard scheduledSnapshotPrewarm == nil else {
            return
        }

        guard !isPrewarmRendering else {
            logger.notice("Snapshot prewarm schedule skipped reason=\(reason, privacy: .public) cause=rendering")
            return
        }

        guard !prewarmQueue.isEmpty else {
            return
        }

        guard activeTransition == nil else {
            logger.notice("Snapshot prewarm skipped due to active transition reason=\(reason, privacy: .public) transition=\(self.activeTransitionDescription, privacy: .public)")
            return
        }

        guard !isSettling else {
            logger.notice("Snapshot prewarm skipped due to settle reason=\(reason, privacy: .public)")
            return
        }

        let next = prewarmQueue[0]
        let now = ProcessInfo.processInfo.systemUptime
        let priorityIdleWindow = idleWindow(for: next.priority)
        let idleDelay = max(0, priorityIdleWindow - (now - lastUserInputTime))
        let shortGapDelay = max(0, prewarmMinimumGap - (now - lastPrewarmEndTime))
        let longRenderDelay = lastPrewarmDuration > 0.05
            ? max(0, prewarmLongRenderGap - (now - lastPrewarmEndTime))
            : 0
        let delay = max(idleDelay, shortGapDelay, longRenderDelay)
        let token = snapshotPrewarmToken
        let idleMs = (now - lastUserInputTime) * 1000
        let gapMs = (now - lastPrewarmEndTime) * 1000
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.performNextSnapshotPrewarm(token: token)
            }
        }
        scheduledSnapshotPrewarm = workItem
        logger.notice(
            "Snapshot prewarm scheduled token=\(token) reason=\(reason, privacy: .public) page=\(next.pageIndex) role=\(next.role, privacy: .public) priority=\(next.priority.description, privacy: .public) delay=\(delay, format: .fixed(precision: 3)) idleMs=\(idleMs, format: .fixed(precision: 1)) gapMs=\(gapMs, format: .fixed(precision: 1)) pending=\(self.prewarmQueue.count)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func idleWindow(for priority: SnapshotPrewarmPriority) -> TimeInterval {
        switch priority {
        case .adjacentPrimary:
            prewarmIdleWindow
        case .adjacentSecondary:
            0.35
        case .farDirection:
            2.50
        case .longIdle:
            8.00
        }
    }

    private func performNextSnapshotPrewarm(token: UInt64) {
        scheduledSnapshotPrewarm = nil
        guard token == snapshotPrewarmToken else {
            logger.notice("Snapshot prewarm invalidated by generation token=\(token) latest=\(self.snapshotPrewarmToken)")
            return
        }

        guard !isPrewarmRendering else {
            logger.notice("Snapshot prewarm skipped reason=already-rendering token=\(token)")
            return
        }

        guard activeTransition == nil else {
            logger.notice("Snapshot prewarm skipped due to active transition token=\(token) transition=\(self.activeTransitionDescription, privacy: .public)")
            return
        }

        guard !isSettling else {
            logger.notice("Snapshot prewarm skipped due to settle token=\(token)")
            return
        }

        guard !prewarmQueue.isEmpty else {
            return
        }

        let next = prewarmQueue[0]
        let now = ProcessInfo.processInfo.systemUptime
        let idleInterval = now - lastUserInputTime
        let requiredIdleWindow = idleWindow(for: next.priority)
        guard idleInterval >= requiredIdleWindow else {
            logger.notice(
                "Snapshot prewarm skipped due to interaction token=\(token) idleMs=\(idleInterval * 1000, format: .fixed(precision: 1)) requiredMs=\(requiredIdleWindow * 1000, format: .fixed(precision: 1))"
            )
            scheduleNextSnapshotPrewarm(reason: "idle-window-not-met")
            return
        }

        let task = prewarmQueue.removeFirst()
        queuedPrewarmKeys.remove(task.key)
        guard task.controllerGeneration == controllerGeneration else {
            logger.notice(
                "Snapshot prewarm invalidated by generation token=\(token) taskGeneration=\(task.controllerGeneration) currentGeneration=\(self.controllerGeneration) page=\(task.pageIndex)"
            )
            scheduleNextSnapshotPrewarm(reason: "after-generation-skip")
            return
        }

        guard pages.indices.contains(task.pageIndex) else {
            logger.notice("Snapshot prewarm canceled page-out-of-range token=\(token) page=\(task.pageIndex)")
            scheduleNextSnapshotPrewarm(reason: "after-range-skip")
            return
        }

        if snapshotCache.entry(for: task.key) != nil {
            logger.notice("Snapshot prewarm skipped due to cache hit token=\(token) key=\(task.key.description, privacy: .public) page=\(task.pageIndex)")
            scheduleNextSnapshotPrewarm(reason: "after-cache-hit-skip")
            return
        }

        let surface = surface(forRole: task.role)
        guard !surface.isPagingLocked,
              activeTransition?.contains(surface) != true,
              canRefreshOffscreen(surface: surface, expectedRole: task.role) else {
            logger.notice(
                "Snapshot prewarm skipped due to unsafe surface token=\(token) page=\(task.pageIndex) role=\(task.role, privacy: .public) state=\(self.surfaceState(surface), privacy: .public) transition=\(self.activeTransitionDescription, privacy: .public)"
            )
            scheduleNextSnapshotPrewarm(reason: "after-unsafe-surface")
            return
        }

        isPrewarmRendering = true
        let renderStart = ContinuousClock.now
        let inputGapMs = (ProcessInfo.processInfo.systemUptime - lastUserInputTime) * 1000
        logger.notice(
            "Snapshot prewarm started token=\(token) page=\(task.pageIndex) role=\(task.role, privacy: .public) priority=\(task.priority.description, privacy: .public) reason=\(task.reason, privacy: .public) inputGapMs=\(inputGapMs, format: .fixed(precision: 1))"
        )
        configure(
            surface: surface,
            pageIndex: task.pageIndex,
            layout: task.layout,
            iconCache: task.iconCache,
            generation: cache.nextGeneration(),
            onLaunch: task.onLaunch,
            reason: "idle-prewarm-\(task.priority.description)-page-\(task.pageIndex)",
            renderImmediately: true
        )
        let renderMs = milliseconds(renderStart.duration(to: .now))
        lastPrewarmDuration = renderMs / 1000
        lastPrewarmEndTime = ProcessInfo.processInfo.systemUptime

        if let restorePageIndex = task.restorePageIndex,
           surface.pageIndex != restorePageIndex,
           pages.indices.contains(restorePageIndex) {
            logger.notice(
                "Snapshot prewarm restoring surface token=\(token) role=\(task.role, privacy: .public) restorePage=\(restorePageIndex)"
            )
            configure(
                surface: surface,
                pageIndex: restorePageIndex,
                layout: task.layout,
                iconCache: task.iconCache,
                generation: cache.nextGeneration(),
                onLaunch: task.onLaunch,
                reason: "idle-prewarm-restore-\(restorePageIndex)",
                renderImmediately: false
            )
        }

        isPrewarmRendering = false
        let summary = snapshotCache.summary
        logger.notice(
            "Snapshot prewarm completed token=\(token) page=\(task.pageIndex) role=\(task.role, privacy: .public) renderMs=\(renderMs, format: .fixed(precision: 2)) count=\(summary.count) bytes=\(summary.estimatedBytes) pending=\(self.prewarmQueue.count)"
        )
        if renderMs > 16 {
            logger.notice("Snapshot prewarm frame-budget exceeded token=\(token) page=\(task.pageIndex) renderMs=\(renderMs, format: .fixed(precision: 2))")
        }
        scheduleNextSnapshotPrewarm(reason: "after-complete")
    }

    private func performScheduledOffscreenRefresh(_ request: OffscreenRefreshRequest) {
        guard request.token == offscreenRefreshToken else {
            logger.notice(
                "Surface offscreen refresh ignored stale token=\(request.token) latest=\(self.offscreenRefreshToken)"
            )
            return
        }

        scheduledOffscreenRefresh = nil
        guard activeTransition == nil, !isSettling else {
            logger.notice(
                "Surface offscreen refresh canceled busy token=\(request.token) settling=\(self.isSettling) transition=\(self.activeTransitionDescription, privacy: .public)"
            )
            return
        }

        guard currentPage == request.targetPage else {
            logger.notice(
                "Surface offscreen refresh canceled page-changed token=\(request.token) expectedCurrent=\(request.targetPage) actualCurrent=\(self.currentPage)"
            )
            return
        }

        let surface = surface(forRole: request.expectedRole)
        guard canRefreshOffscreen(surface: surface, expectedRole: request.expectedRole) else {
            logger.notice(
                "Surface offscreen refresh canceled not-offscreen token=\(request.token) role=\(request.expectedRole, privacy: .public) requestedPage=\(request.requestedPage) state=\(self.surfaceState(surface), privacy: .public)"
            )
            return
        }

        logger.notice(
            "Surface offscreen refresh executing token=\(request.token) role=\(request.expectedRole, privacy: .public) requestedPage=\(request.requestedPage) settling=\(self.isSettling) transition=\(self.activeTransitionDescription, privacy: .public)"
        )
        refreshOffscreenSurface(
            after: request.direction,
            targetPage: request.targetPage,
            layout: request.layout,
            iconCache: request.iconCache,
            onLaunch: request.onLaunch,
            token: request.token
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
        onLaunch: @escaping (AppItem) -> Void,
        reason: String,
        renderImmediately: Bool = true
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

        let pageApps = pageApps(for: pageIndex)
        let snapshotKey = makeSnapshotKey(
            pageIndex: pageIndex,
            apps: pageApps,
            layout: layout,
            surface: surface,
            iconCache: iconCache
        )

        if let snapshotKey,
           let entry = snapshotCache.entry(for: snapshotKey) {
            let bindStart = ContinuousClock.now
            surface.configure(
                pageIndex: pageIndex,
                apps: pageApps,
                layout: layout,
                iconCache: iconCache,
                generation: generation,
                onLaunch: onLaunch,
                cachedSnapshot: entry.snapshot
            )
            let elapsed = milliseconds(bindStart.duration(to: .now))
            let summary = snapshotCache.summary
            logger.notice(
                "Snapshot cache hit reason=\(reason, privacy: .public) key=\(snapshotKey.description, privacy: .public) bindMs=\(elapsed, format: .fixed(precision: 2)) count=\(summary.count) bytes=\(summary.estimatedBytes)"
            )
            return
        }

        if let snapshotKey {
            logger.notice("Snapshot cache miss reason=\(reason, privacy: .public) key=\(snapshotKey.description, privacy: .public)")
        } else {
            logger.notice("Snapshot cache skipped reason=\(reason, privacy: .public) page=\(pageIndex)")
        }

        surface.configure(
            pageIndex: pageIndex,
            apps: pageApps,
            layout: layout,
            iconCache: iconCache,
            generation: generation,
            onLaunch: onLaunch,
            deferRender: true
        )
        guard renderImmediately else {
            logger.notice("Snapshot render deferred reason=\(reason, privacy: .public) page=\(pageIndex)")
            return
        }

        let renderStart = ContinuousClock.now
        logger.notice("Snapshot render started reason=\(reason, privacy: .public) page=\(pageIndex)")
        let snapshot = surface.forceRenderIfNeeded()
        let elapsed = milliseconds(renderStart.duration(to: .now))
        logger.notice(
            "Snapshot cache miss render reason=\(reason, privacy: .public) page=\(pageIndex) renderMs=\(elapsed, format: .fixed(precision: 2)) cacheable=\(snapshot != nil)"
        )
        if let snapshot {
            let renderedKey = makeSnapshotKey(
                pageIndex: pageIndex,
                apps: pageApps,
                layout: layout,
                surface: surface,
                iconCache: iconCache
            )
            if let snapshotKey, let renderedKey, snapshotKey != renderedKey {
                logger.notice(
                    "Snapshot cache key changed during render reason=\(reason, privacy: .public) before=\(snapshotKey.description, privacy: .public) after=\(renderedKey.description, privacy: .public)"
                )
            }
            if let renderedKey {
                insert(snapshot: snapshot, for: renderedKey, reason: reason)
            }
        } else if let snapshotKey {
            logger.notice("Snapshot cache insert skipped key=\(snapshotKey.description, privacy: .public) reason=not-cacheable")
        }
    }

    private func insertRenderedSnapshotIfPossible(
        surface: PageSurfaceView,
        layout: LaunchpadLayout,
        iconCache: IconCache,
        reason: String
    ) {
        let apps = pageApps(for: surface.pageIndex)
        guard let key = makeSnapshotKey(
            pageIndex: surface.pageIndex,
            apps: apps,
            layout: layout,
            surface: surface,
            iconCache: iconCache
        ) else {
            logger.notice("Snapshot cache prewarm skipped reason=\(reason, privacy: .public) page=\(surface.pageIndex)")
            return
        }

        if snapshotCache.entry(for: key) != nil {
            logger.notice("Snapshot cache prewarm already cached reason=\(reason, privacy: .public) key=\(key.description, privacy: .public)")
            return
        }

        guard let snapshot = surface.renderedSnapshotIfCacheable() else {
            logger.notice("Snapshot cache prewarm skipped reason=\(reason, privacy: .public) key=\(key.description, privacy: .public) cause=not-cacheable")
            return
        }

        insert(snapshot: snapshot, for: key, reason: reason)
    }

    private func insertRenderedSnapshot(
        surface: PageSurfaceView,
        snapshot: PageSurfaceSnapshot,
        reason: String
    ) {
        guard let layout, let iconCache else {
            return
        }

        let apps = pageApps(for: surface.pageIndex)
        guard let key = makeSnapshotKey(
            pageIndex: surface.pageIndex,
            apps: apps,
            layout: layout,
            surface: surface,
            iconCache: iconCache
        ) else {
            return
        }

        insert(snapshot: snapshot, for: key, reason: reason)
    }

    private func isSnapshotCached(
        pageIndex: Int,
        surface: PageSurfaceView,
        layout: LaunchpadLayout,
        iconCache: IconCache
    ) -> Bool {
        guard let key = makeSnapshotKey(
            pageIndex: pageIndex,
            apps: pageApps(for: pageIndex),
            layout: layout,
            surface: surface,
            iconCache: iconCache
        ) else {
            return false
        }

        return snapshotCache.entry(for: key) != nil
    }

    private func insert(
        snapshot: PageSurfaceSnapshot,
        for key: PageSnapshotCache.Key,
        reason: String
    ) {
        if snapshotCache.entry(for: key) != nil {
            logger.notice("Snapshot cache insert skipped existing reason=\(reason, privacy: .public) key=\(key.description, privacy: .public)")
            return
        }

        let evicted = snapshotCache.insert(
            snapshot: snapshot,
            for: key,
            protectedKeys: protectedSnapshotKeys()
        )
        let summary = snapshotCache.summary
        logger.notice(
            "Snapshot cache insert reason=\(reason, privacy: .public) key=\(key.description, privacy: .public) point=\(Int(snapshot.pointSize.width))x\(Int(snapshot.pointSize.height)) pixel=\(Int(snapshot.pixelSize.width))x\(Int(snapshot.pixelSize.height)) scale=\(snapshot.scale, format: .fixed(precision: 2)) bytes=\(snapshot.byteCost) count=\(summary.count) totalBytes=\(summary.estimatedBytes)"
        )
        for entry in evicted {
            logger.notice(
                "Snapshot cache evict key=\(entry.key.description, privacy: .public) bytes=\(entry.snapshot.byteCost) count=\(summary.count) totalBytes=\(summary.estimatedBytes)"
            )
        }
    }

    private func protectedSnapshotKeys() -> Set<PageSnapshotCache.Key> {
        guard let layout, let iconCache else {
            return []
        }

        return Set([previousSurface, currentSurface, nextSurface].compactMap { surface in
            makeSnapshotKey(
                pageIndex: surface.pageIndex,
                apps: pageApps(for: surface.pageIndex),
                layout: layout,
                surface: surface,
                iconCache: iconCache
            )
        })
    }

    private func makeSnapshotKey(
        pageIndex: Int,
        apps: [AppItem],
        layout: LaunchpadLayout,
        surface: PageSurfaceView,
        iconCache: IconCache
    ) -> PageSnapshotCache.Key? {
        guard pages.indices.contains(pageIndex),
              !debugSurfaceBordersEnabled,
              surface.bounds.width > 1,
              surface.bounds.height > 1 else {
            return nil
        }

        let scale = surface.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let appearance = surface.effectiveAppearance.bestMatch(from: [
            .aqua,
            .darkAqua,
            .accessibilityHighContrastAqua,
            .accessibilityHighContrastDarkAqua
        ])?.rawValue ?? "unknown"
        let contentSignature = apps.map { app in
            [
                app.id,
                app.name,
                app.bundleIdentifier ?? "",
                app.normalizedPath
            ].joined(separator: "|")
        }.joined(separator: "\u{1f}")
        let iconSignature = apps.map { app in
            "\(app.normalizedPath)=\(iconCache.snapshotGeneration(forPath: app.normalizedPath))"
        }.joined(separator: "\u{1f}")

        return PageSnapshotCache.Key(
            pageIndex: pageIndex,
            contentSignature: contentSignature,
            layoutSignature: layoutSignature(layout),
            pointWidth: quantized(surface.bounds.width),
            pointHeight: quantized(surface.bounds.height),
            scale: quantized(scale),
            appearanceSignature: appearance,
            iconSignature: iconSignature
        )
    }

    private func pageApps(for pageIndex: Int) -> [AppItem] {
        pages.indices.contains(pageIndex) ? pages[pageIndex] : []
    }

    private func layoutSignature(_ layout: LaunchpadLayout) -> String {
        [
            "columns=\(layout.columns)",
            "rows=\(layout.rows)",
            "capacity=\(layout.pageCapacity)",
            "icon=\(quantized(layout.iconSize))",
            "labelWidth=\(quantized(layout.labelWidth))",
            "labelHeight=\(quantized(layout.labelHeight))",
            "labelFont=\(quantized(layout.labelFontSize))",
            "cellWidth=\(quantized(layout.cellWidth))",
            "cellHeight=\(quantized(layout.cellHeight))",
            "columnSpacing=\(quantized(layout.columnSpacing))",
            "rowSpacing=\(quantized(layout.rowSpacing))",
            "gridWidth=\(quantized(layout.gridWidth))",
            "gridHeight=\(quantized(layout.gridHeight))",
            "pageWidth=\(quantized(layout.pageWidth))",
            "contentX=\(quantized(layout.contentFrame.minX))",
            "contentY=\(quantized(layout.contentFrame.minY))",
            "contentW=\(quantized(layout.contentFrame.width))",
            "contentH=\(quantized(layout.contentFrame.height))"
        ].joined(separator: ";")
    }

    private func quantized(_ value: CGFloat) -> Int {
        Int((value * 100).rounded())
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
        activeSettleCompletion = completion
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
            guard let self else {
                return
            }
            guard self.settleGeneration == settleID else {
                self.logger.notice(
                    "Surface stale settle completion ignored settleID=\(settleID) currentGeneration=\(self.settleGeneration)"
                )
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
        activeSettleCompletion = nil
        logger.notice("Surface settle ended page=\(self.currentPage) generation=\(self.settleGeneration)")
        var offscreenRefresh: OffscreenRefreshRequest?
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch completion {
        case .cancel:
            setTranslation(0, alignToPixel: true)
            clearActiveTransition()
        case let .commit(direction, targetPage, layout, iconCache, onLaunch, commitPage):
            offscreenRefresh = commitActiveTransition(
                direction: direction,
                targetPage: targetPage,
                layout: layout,
                iconCache: iconCache,
                onLaunch: onLaunch,
                reason: "settle-completion",
                commitPage: commitPage
            )
        }
        CATransaction.commit()
        gestureStartTranslation = 0
        isSettling = false
        driver.reset(to: 0)
        driver.start()
        if let offscreenRefresh {
            scheduleOffscreenRefresh(offscreenRefresh)
        }
        if let layout, let iconCache, let onLaunch {
            enqueueStartupPrewarm(layout: layout, iconCache: iconCache, onLaunch: onLaunch, reason: "settle-complete")
        }
        exportMotionCSVIfNeeded()
        logger.notice("Surface settle complete page=\(self.currentPage) surfaceCount=\(self.transitionView.subviews.count)")
    }

    private func commitActiveTransition(
        direction: PagingDirection,
        targetPage: Int,
        layout: LaunchpadLayout,
        iconCache: IconCache,
        onLaunch: @escaping (AppItem) -> Void,
        reason: String,
        commitPage: () -> Void
    ) -> OffscreenRefreshRequest {
        let rotationStart = ContinuousClock.now
        let transition = activeTransition
        let centerBefore = centeredSurfaceFrameBeforeRotation(direction: direction)
        let expectedCenterSurface = destinationSurface(for: direction)
        logger.notice(
            "Surface transition commit began reason=\(reason, privacy: .public) session=\(transition?.sessionID ?? 0) generation=\(self.settleGeneration) direction=\(direction.rawValue, privacy: .public) pageBefore=\(self.currentPage) targetPage=\(targetPage) previous=\(self.surfaceState(self.previousSurface), privacy: .public) current=\(self.surfaceState(self.currentSurface), privacy: .public) next=\(self.surfaceState(self.nextSurface), privacy: .public)"
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
        let requestedPage: Int
        let expectedRole: String
        switch direction {
        case .next:
            requestedPage = targetPage + 1
            expectedRole = "next"
        case .previous:
            requestedPage = targetPage - 1
            expectedRole = "previous"
        }
        logger.notice(
            "Surface transition commit ended reason=\(reason, privacy: .public) session=\(transition?.sessionID ?? 0) pageAfter=\(self.currentPage) sameSurface=\(sameSurface) slotError=\(continuityError, format: .fixed(precision: 3)) ms=\(elapsed, format: .fixed(precision: 2)) refreshRole=\(expectedRole, privacy: .public) refreshPage=\(requestedPage) previous=\(self.surfaceState(self.previousSurface), privacy: .public) current=\(self.surfaceState(self.currentSurface), privacy: .public) next=\(self.surfaceState(self.nextSurface), privacy: .public)"
        )

        return OffscreenRefreshRequest(
            token: 0,
            direction: direction,
            targetPage: targetPage,
            requestedPage: requestedPage,
            expectedRole: expectedRole,
            layout: layout,
            iconCache: iconCache,
            onLaunch: onLaunch
        )
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
        let interruptedGeneration = settleGeneration

        if let transition = activeTransition,
           let completion = activeSettleCompletion,
           shouldCommitInterruptedTransition(visibleTranslation: visibleTranslation, transition: transition) {
            activeSettleCompletion = nil
            logger.notice(
                "Surface settle interrupted near full page reason=\(reason, privacy: .public) session=\(transition.sessionID) generation=\(interruptedGeneration) visibleTranslation=\(visibleTranslation) pageWidth=\(self.pageWidth) pageBefore=\(self.currentPage) direction=\(transition.direction.rawValue, privacy: .public)"
            )

            let targetTranslation = targetTranslation(for: transition.direction)
            var offscreenRefresh: OffscreenRefreshRequest?
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            transitionView.layer?.removeAnimation(forKey: "surface-settle")
            transitionView.layer?.transform = CATransform3DMakeTranslation(targetTranslation, 0, 0)
            switch completion {
            case .cancel:
                setTranslation(0, alignToPixel: true)
                clearActiveTransition()
            case let .commit(direction, targetPage, layout, iconCache, onLaunch, commitPage):
                offscreenRefresh = commitActiveTransition(
                    direction: direction,
                    targetPage: targetPage,
                    layout: layout,
                    iconCache: iconCache,
                    onLaunch: onLaunch,
                    reason: "near-full-interrupt",
                    commitPage: commitPage
                )
            }
            CATransaction.commit()

            gestureStartTranslation = 0
            isSettling = false
            driver.reset(to: 0)
            driver.start()
            if let offscreenRefresh {
                scheduleOffscreenRefresh(offscreenRefresh)
            }
            exportMotionCSVIfNeeded()
            logger.notice(
                "Surface settle interrupt committed session=\(transition.sessionID) pageAfter=\(self.currentPage) generation=\(self.settleGeneration)"
            )
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        transitionView.layer?.removeAnimation(forKey: "surface-settle")
        transitionView.layer?.transform = CATransform3DMakeTranslation(visibleTranslation, 0, 0)
        CATransaction.commit()

        activeSettleCompletion = nil
        currentTranslation = visibleTranslation
        gestureStartTranslation = visibleTranslation
        driver.reset(to: visibleTranslation)
        isSettling = false
        updateDebugSurfaceVisuals()
        logger.notice(
            "Surface settle interrupted reason=\(reason, privacy: .public) generation=\(interruptedGeneration) visibleTranslation=\(visibleTranslation) page=\(self.currentPage)"
        )
    }

    private func shouldCommitInterruptedTransition(
        visibleTranslation: CGFloat,
        transition: ActivePagingTransition
    ) -> Bool {
        guard pageWidth > 0 else {
            return false
        }

        let target = targetTranslation(for: transition.direction)
        return abs(visibleTranslation) >= pageWidth * 0.95
            && visibleTranslation * target > 0
    }

    private func targetTranslation(for direction: PagingDirection) -> CGFloat {
        switch direction {
        case .next:
            -pageWidth
        case .previous:
            pageWidth
        }
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

    private func surface(forRole role: String) -> PageSurfaceView {
        switch role {
        case "previous":
            previousSurface
        case "current":
            currentSurface
        case "next":
            nextSurface
        default:
            currentSurface
        }
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
