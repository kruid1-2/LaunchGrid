import AppKit

@MainActor
final class PageSurfaceView: NSView {
    private let contentLayer = CALayer()
    private var apps: [AppItem] = []
    private var layout: LaunchpadLayout?
    private weak var iconCache: IconCache?
    private var iconImages: [String: NSImage] = [:]
    private(set) var generation = 0
    private(set) var pageIndex = Int.min
    private var hoveredIndex: Int?
    private var pressedIndex: Int?
    private var mouseDownPoint: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var onLaunch: ((AppItem) -> Void)?
    private var displayRefreshScheduled = false
    private(set) var isPagingLocked = false
    private var renderedGeneration = Int.min
    private var isRenderingSurfaceCache = false
    private var debugOverlayText: String?

    private let labelParagraphStyle: NSParagraphStyle = {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byTruncatingTail
        return paragraphStyle
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        contentLayer.masksToBounds = false
        contentLayer.contentsGravity = .resize
        contentLayer.actions = [
            "bounds": NSNull(),
            "contents": NSNull(),
            "frame": NSNull(),
            "position": NSNull()
        ]
        layer?.addSublayer(contentLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func configure(
        pageIndex: Int,
        apps: [AppItem],
        layout: LaunchpadLayout,
        iconCache: IconCache,
        generation: Int,
        onLaunch: @escaping (AppItem) -> Void
    ) {
        self.pageIndex = pageIndex
        self.apps = apps
        self.layout = layout
        self.iconCache = iconCache
        self.generation = generation
        renderedGeneration = Int.min
        self.hoveredIndex = nil
        self.pressedIndex = nil
        self.mouseDownPoint = nil
        self.onLaunch = onLaunch
        toolTip = nil

        let validPaths = Set(apps.map(\.normalizedPath))
        iconImages = iconImages.filter { validPaths.contains($0.key) }
        requestMissingIcons(iconCache: iconCache, generation: generation)
        markNeedsSurfaceRefresh()
    }

    var hasDrawableContent: Bool {
        layout != nil
    }

    var hasRenderedCurrentGeneration: Bool {
        renderedGeneration == generation
    }

    func setDebugBorder(_ color: NSColor?) {
        guard let layer else {
            return
        }

        if let color {
            layer.borderWidth = 3
            layer.borderColor = color.cgColor
        } else {
            layer.borderWidth = 0
            layer.borderColor = nil
        }
    }

    func setPagingLocked(_ locked: Bool) {
        guard isPagingLocked != locked else {
            return
        }

        isPagingLocked = locked
        markNeedsSurfaceRefresh()
    }

    func setDebugOverlay(_ text: String?) {
        guard debugOverlayText != text else {
            return
        }

        debugOverlayText = text
        markNeedsSurfaceRefresh()
    }

    var appCount: Int {
        apps.count
    }

    var hasPendingDisplayRefresh: Bool {
        displayRefreshScheduled
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .mouseMoved,
            .mouseEnteredAndExited,
            .inVisibleRect
        ]
        let nextTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(nextTrackingArea)
        trackingArea = nextTrackingArea
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isRenderingSurfaceCache else {
            return
        }

        drawSurface(in: dirtyRect)
    }

    private func drawSurface(in dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()

        guard let layout else {
            return
        }

        guard !apps.isEmpty else {
            drawEmptyState(layout: layout)
            renderedGeneration = generation
            return
        }

        NSGraphicsContext.current?.imageInterpolation = .high
        for index in apps.indices {
            drawApp(at: index, layout: layout)
        }
        drawDebugOverlayIfNeeded()
        renderedGeneration = generation
    }

    func forceRenderIfNeeded() {
        guard !isPagingLocked else {
            needsDisplay = true
            return
        }

        layoutSubtreeIfNeeded()
        contentLayer.frame = bounds
        guard bounds.width > 1, bounds.height > 1 else {
            displayIfNeeded()
            layer?.displayIfNeeded()
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = max(1, Int(ceil(bounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(bounds.height * scale)))
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmapContext = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo
              ) else {
            displayIfNeeded()
            layer?.displayIfNeeded()
            return
        }

        bitmapContext.translateBy(x: 0, y: CGFloat(pixelHeight))
        bitmapContext.scaleBy(x: scale, y: -scale)
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmapContext, flipped: true)
        isRenderingSurfaceCache = true
        drawSurface(in: bounds)
        isRenderingSurfaceCache = false
        NSGraphicsContext.current = previousContext

        contentLayer.contents = bitmapContext.makeImage()
        contentLayer.contentsScale = scale
        renderedGeneration = generation
        needsDisplay = false
    }

    override func mouseMoved(with event: NSEvent) {
        let index = hitIndex(at: convert(event.locationInWindow, from: nil))
        if hoveredIndex != index {
            hoveredIndex = index
            markNeedsSurfaceRefresh()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil || pressedIndex != nil {
            hoveredIndex = nil
            pressedIndex = nil
            markNeedsSurfaceRefresh()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        pressedIndex = hitIndex(at: point)
        markNeedsSurfaceRefresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownPoint, let layout else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let distance = hypot(point.x - mouseDownPoint.x, point.y - mouseDownPoint.y)
        let nextPressedIndex = distance <= layout.clickCancelDistance ? hitIndex(at: point) : nil
        if pressedIndex != nextPressedIndex {
            pressedIndex = nextPressedIndex
            markNeedsSurfaceRefresh()
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressedIndex = nil
            mouseDownPoint = nil
            markNeedsSurfaceRefresh()
        }

        let point = convert(event.locationInWindow, from: nil)
        guard let pressedIndex,
              pressedIndex == hitIndex(at: point),
              apps.indices.contains(pressedIndex) else {
            return
        }

        onLaunch?(apps[pressedIndex])
    }

    func cancelPointerInteraction() {
        guard pressedIndex != nil || mouseDownPoint != nil else {
            return
        }

        pressedIndex = nil
        mouseDownPoint = nil
        markNeedsSurfaceRefresh()
    }

    func app(atLocalPoint point: CGPoint) -> AppItem? {
        guard let index = hitIndex(at: point),
              apps.indices.contains(index) else {
            return nil
        }

        return apps[index]
    }

    private func requestMissingIcons(iconCache: IconCache, generation: Int) {
        for app in apps {
            let path = app.normalizedPath
            if let image = iconCache.cachedIcon(forPath: path) {
                iconImages[path] = image
                continue
            }

            iconCache.loadIcon(forPath: path) { [weak self] image in
                guard let self, self.generation == generation else {
                    return
                }

                self.iconImages[path] = image
                self.scheduleDisplayRefresh(for: generation)
            }
        }
    }

    private func drawApp(at index: Int, layout: LaunchpadLayout) {
        let row = index / layout.columns
        let column = index % layout.columns
        guard row < layout.rows else {
            return
        }

        let gridOriginX = max(0, (bounds.width - layout.gridWidth) / 2)
        let cellX = gridOriginX + CGFloat(column) * (layout.cellWidth + layout.columnSpacing)
        let cellY = CGFloat(row) * (layout.cellHeight + layout.rowSpacing)
        let app = apps[index]

        drawIcon(app: app, index: index, cellX: cellX, cellY: cellY, layout: layout)
        drawLabel(app.name, cellX: cellX, cellY: cellY, layout: layout)
    }

    private func drawIcon(
        app: AppItem,
        index: Int,
        cellX: CGFloat,
        cellY: CGFloat,
        layout: LaunchpadLayout
    ) {
        let icon = iconImages[app.normalizedPath]
            ?? iconCache?.cachedIcon(forPath: app.normalizedPath)
            ?? iconCache?.placeholderIcon
            ?? NSWorkspace.shared.icon(for: .applicationBundle)

        let scale: CGFloat
        if pressedIndex == index {
            scale = 0.96
        } else if hoveredIndex == index {
            scale = 1.025
        } else {
            scale = 1
        }

        let iconSize = layout.iconSize * scale
        let iconRect = CGRect(
            x: cellX + (layout.cellWidth - iconSize) / 2,
            y: cellY + (layout.iconSize - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.set()
        icon.draw(
            in: iconRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawLabel(_ name: String, cellX: CGFloat, cellY: CGFloat, layout: LaunchpadLayout) {
        let labelRect = CGRect(
            x: cellX,
            y: cellY + layout.iconSize + labelGap(for: layout),
            width: layout.labelWidth,
            height: layout.labelHeight
        )
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: layout.labelFontSize, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .paragraphStyle: labelParagraphStyle
        ]

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.72)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        (name as NSString).draw(
            with: labelRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: labelAttributes
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawEmptyState(layout: LaunchpadLayout) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.76),
            .paragraphStyle: paragraph
        ]
        let rect = CGRect(
            x: 0,
            y: max(0, bounds.midY - 12),
            width: bounds.width,
            height: 24
        )

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.65)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        ("No applications found" as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
        NSGraphicsContext.restoreGraphicsState()
        drawDebugOverlayIfNeeded()
    }

    private func drawDebugOverlayIfNeeded() {
        guard let debugOverlayText, !debugOverlayText.isEmpty else {
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.55),
            .paragraphStyle: paragraph
        ]
        let rect = CGRect(x: 10, y: 10, width: 230, height: 54)
        (debugOverlayText as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes
        )
    }

    private func labelGap(for layout: LaunchpadLayout) -> CGFloat {
        max(2, min(8, layout.cellHeight - layout.iconSize - layout.labelHeight))
    }

    private func scheduleDisplayRefresh(for generation: Int) {
        guard !displayRefreshScheduled else {
            return
        }

        displayRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            guard let self else {
                return
            }

            self.displayRefreshScheduled = false
            guard self.generation == generation else {
                return
            }

            self.markNeedsSurfaceRefresh()
        }
    }

    private func markNeedsSurfaceRefresh() {
        needsDisplay = true
        guard window != nil else {
            return
        }

        forceRenderIfNeeded()
    }

    private func hitIndex(at point: CGPoint) -> Int? {
        guard let layout else {
            return nil
        }

        let gridOriginX = max(0, (bounds.width - layout.gridWidth) / 2)
        for index in apps.indices {
            let row = index / layout.columns
            let column = index % layout.columns
            guard row < layout.rows else {
                continue
            }

            let cellFrame = CGRect(
                x: gridOriginX + CGFloat(column) * (layout.cellWidth + layout.columnSpacing),
                y: CGFloat(row) * (layout.cellHeight + layout.rowSpacing),
                width: layout.cellWidth,
                height: layout.cellHeight
            )
            if cellFrame.contains(point) {
                return index
            }
        }

        return nil
    }
}
