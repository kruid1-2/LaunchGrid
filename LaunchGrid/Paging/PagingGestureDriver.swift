import AppKit
import CoreVideo
import QuartzCore

@MainActor
final class PagingGestureDriver {
    private var displayLink: CVDisplayLink?
    private let onFrame: (CGFloat) -> Void
    private let onSample: ((TimeInterval, CGFloat, CGFloat) -> Void)?
    private let responseTime: TimeInterval
    private var targetTranslation: CGFloat = 0
    private var displayedTranslation: CGFloat = 0
    private var lastFrameTime: TimeInterval?

    init(
        responseTime: TimeInterval = 0.018,
        onSample: ((TimeInterval, CGFloat, CGFloat) -> Void)? = nil,
        onFrame: @escaping (CGFloat) -> Void
    ) {
        self.responseTime = responseTime
        self.onSample = onSample
        self.onFrame = onFrame

        var link: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard result == kCVReturnSuccess, let link else {
            return
        }

        displayLink = link
        CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo in
            guard let userInfo else {
                return kCVReturnSuccess
            }

            let driver = Unmanaged<PagingGestureDriver>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                driver.displayLinkTick()
            }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    func start() {
        guard let displayLink, !CVDisplayLinkIsRunning(displayLink) else {
            return
        }

        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        guard let displayLink, CVDisplayLinkIsRunning(displayLink) else {
            return
        }

        CVDisplayLinkStop(displayLink)
    }

    func setTarget(_ translation: CGFloat) {
        targetTranslation = translation
    }

    func reset(to translation: CGFloat = 0) {
        targetTranslation = translation
        displayedTranslation = translation
        lastFrameTime = nil
        onFrame(translation)
        onSample?(CACurrentMediaTime(), targetTranslation, displayedTranslation)
    }

    var currentTarget: CGFloat {
        targetTranslation
    }

    var currentDisplayed: CGFloat {
        displayedTranslation
    }

    private func displayLinkTick() {
        let now = CACurrentMediaTime()
        let deltaTime = min(1.0 / 20.0, max(1.0 / 240.0, now - (lastFrameTime ?? now - 1.0 / 60.0)))
        lastFrameTime = now

        let difference = targetTranslation - displayedTranslation
        guard abs(difference) >= 0.05 else {
            displayedTranslation = targetTranslation
            onFrame(displayedTranslation)
            onSample?(now, targetTranslation, displayedTranslation)
            return
        }

        let alpha = 1 - exp(-deltaTime / responseTime)
        displayedTranslation += difference * CGFloat(alpha)
        onFrame(displayedTranslation)
        onSample?(now, targetTranslation, displayedTranslation)
    }
}
