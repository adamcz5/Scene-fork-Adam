import AppKit
import QuartzCore
import SceneCore

/// One borderless, click-through, non-activating panel per `NSScreen` that
/// darkens + blurs the whole screen except the rect(s) punched out of it.
///
/// Darkening comes from tint views (black at `config.darkness`); blurring from
/// `NSVisualEffectView`s in `.behindWindow` mode. Each gets its own
/// `CAShapeLayer` even-odd mask. Overlapping hole rects are pre-merged via
/// `RectMerging.mergingOverlapping`.
///
/// Soft edges: with edge softness > 0 the overlay is built from several stacked
/// tint/blur layers whose holes are progressively larger, so the dim ramps up
/// over a few points around each hole instead of cutting off sharply. Each
/// layer carries a share of the total opacity so the stack adds up to the
/// chosen darkness / blur.
///
/// Darkness and blur changes can be applied live (`apply(config:animated:)`),
/// gliding from the current look to the new one instead of restarting the dim.
final class SpotlightOverlayWindow: NSPanel {
    /// Fade durations at `speed == 1`; actual duration is `base / speed`.
    static let baseShowAnimationDuration: TimeInterval = 0.35
    static let baseHideAnimationDuration: TimeInterval = 0.15
    private static let liveChangeDuration: TimeInterval = 0.3
    private static let featherSteps = 5
    static let edgePointsPerLevel: CGFloat = 4

    private var speed: Double = SpotlightConfig.defaultSpeed
    private var showAnimationDuration: TimeInterval { Self.baseShowAnimationDuration / speed }
    /// Un-dimming is always the same quick fade, independent of the fade-speed setting.
    private var hideAnimationDuration: TimeInterval { Self.baseHideAnimationDuration }

    private final class Stage {
        let blur = NSVisualEffectView()
        let tint = NSView()
        let blurMask = CAShapeLayer()
        let tintMask = CAShapeLayer()
    }

    private let container: NSView
    private var stages: [Stage] = []
    private var darkness: Double = SpotlightConfig.defaultDarkness
    private var blurAlpha: Double = 1
    private var featherPoints: CGFloat = 0
    private var lastFrames: [CGRect] = []
    private var lastScreenFrame: CGRect = .zero

    init(screen: NSScreen) {
        container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Purely visual — every click must pass straight through to whatever
        // window is actually underneath, dimmed or not.
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        // `.stationary` keeps Mission Control / Exposé from treating this as
        // a real window tile; scoped to the space it was created on.
        collectionBehavior = [.stationary, .ignoresCycle]
        alphaValue = 0

        self.contentView = container
        rebuildStages(count: 1)
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func rebuildStages(count: Int) {
        for stage in stages {
            stage.blur.removeFromSuperview()
            stage.tint.removeFromSuperview()
        }
        stages = (0..<count).map { _ in
            let stage = Stage()
            stage.blur.material = .hudWindow
            stage.blur.blendingMode = .behindWindow
            stage.blur.state = .active
            stage.blur.wantsLayer = true
            stage.blur.layer?.mask = stage.blurMask
            stage.tint.wantsLayer = true
            stage.tint.layer?.mask = stage.tintMask
            for view in [stage.blur, stage.tint] {
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
            }
            return stage
        }
        // blur layers first, tint layers on top
        for stage in stages { container.addSubview(stage.blur) }
        for stage in stages { container.addSubview(stage.tint) }
        applyLook(animated: false)
        if !lastFrames.isEmpty || lastScreenFrame != .zero {
            updateHoles(excludedFrames: lastFrames, screenFrame: lastScreenFrame, animated: false)
        }
    }

    /// Share each of `count` stacked layers must carry so the stack composes to
    /// `total` opacity: 1 - (1 - b)^count = total.
    private func share(of total: Double) -> Double {
        let t = min(max(total, 0), 1)
        return 1 - pow(1 - t, 1.0 / Double(max(stages.count, 1)))
    }

    private func applyLook(animated: Bool) {
        let tintAlpha = share(of: darkness)
        let blurShare = share(of: blurAlpha)
        for stage in stages {
            let newColor = NSColor.black.withAlphaComponent(tintAlpha).cgColor
            if animated, let layer = stage.tint.layer {
                let from = layer.presentation()?.backgroundColor ?? layer.backgroundColor
                let anim = CABasicAnimation(keyPath: "backgroundColor")
                anim.fromValue = from
                anim.toValue = newColor
                anim.duration = Self.liveChangeDuration
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(anim, forKey: "liveTint")
                layer.backgroundColor = newColor
            } else {
                stage.tint.layer?.backgroundColor = newColor
            }
            stage.blur.isHidden = false
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.liveChangeDuration
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    stage.blur.animator().alphaValue = blurShare
                }
            } else {
                stage.blur.alphaValue = blurShare
            }
        }
    }

    /// Pushes the user-tunable look into the views. Safe to call while shown.
    /// `animated` glides darkness/blur/softness from where they are now.
    func apply(config: SpotlightConfig, animated: Bool = false) {
        speed = min(max(config.speed, SpotlightConfig.minSpeed), SpotlightConfig.maxSpeed)
        darkness = min(max(config.darkness, 0), 1)
        switch config.blurPreset {
        case .off: blurAlpha = 0
        case .light: blurAlpha = 0.32
        case .medium: blurAlpha = 0.72
        case .heavy: blurAlpha = 0.9
        }
        let newFeather = CGFloat(min(max(config.edgeSoftness, 0), SpotlightConfig.maxChromeLevel)) * Self.edgePointsPerLevel
        let newCount = newFeather > 0 ? Self.featherSteps : 1
        let featherChanged = newFeather != featherPoints
        featherPoints = newFeather
        if newCount != stages.count {
            rebuildStages(count: newCount)
        } else {
            applyLook(animated: animated)
            if featherChanged, !lastFrames.isEmpty || lastScreenFrame != .zero {
                updateHoles(excludedFrames: lastFrames, screenFrame: lastScreenFrame, animated: animated)
            }
        }
    }

    /// `excludedFrames` are in the global NS screen-coordinate system
    /// (bottom-left origin, matching `NSScreen.frame`). Converts to this
    /// window's own local coordinates (origin at this screen's bottom-left).
    func updateHoles(excludedFrames: [CGRect], screenFrame: CGRect, animated: Bool = false) {
        lastFrames = excludedFrames
        lastScreenFrame = screenFrame
        let count = stages.count
        for (index, stage) in stages.enumerated() {
            // Layer 0 has the biggest hole, the last layer the smallest, so the
            // number of layers dimming a point grows with distance from the hole.
            let grow = count > 1 ? featherPoints * CGFloat(count - index) / CGFloat(count) : 0
            let expanded = excludedFrames.map { $0.insetBy(dx: -grow, dy: -grow) }
            let merged = RectMerging.mergingOverlapping(expanded)
            let path = CGMutablePath()
            path.addRect(CGRect(origin: .zero, size: screenFrame.size))
            for frame in merged {
                let clipped = frame.intersection(screenFrame)
                guard !clipped.isEmpty else { continue }
                path.addRect(CGRect(
                    x: clipped.minX - screenFrame.minX,
                    y: clipped.minY - screenFrame.minY,
                    width: clipped.width,
                    height: clipped.height
                ))
            }
            for mask in [stage.blurMask, stage.tintMask] {
                if animated, let old = mask.path {
                    let anim = CABasicAnimation(keyPath: "path")
                    anim.fromValue = old
                    anim.toValue = path
                    anim.duration = Self.baseHideAnimationDuration
                    anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    mask.add(anim, forKey: "holeMove")
                }
                mask.path = path
                mask.fillRule = .evenOdd
            }
        }
    }

    func show() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = showAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Fades out and orders out once the fade completes. `immediate: true`
    /// skips the fade (used when tearing down entirely, e.g. Spotlight
    /// disabled or Accessibility revoked) rather than for the normal
    /// "dissolve on interaction" path, which always animates.
    func hide(immediate: Bool = false) {
        guard !immediate else {
            alphaValue = 0
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = hideAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A later `show()` during the fade re-raises alphaValue to 1
            // before this completion runs; only order out if we're still
            // actually faded, so a quick switch-back doesn't flash-hide a
            // window that's already fading back in.
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }
}
