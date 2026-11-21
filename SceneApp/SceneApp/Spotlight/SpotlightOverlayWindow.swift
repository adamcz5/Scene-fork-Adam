import AppKit
import QuartzCore
import SceneCore

/// One borderless, click-through, non-activating panel per `NSScreen` that
/// darkens + blurs the whole screen except the rect(s) punched out of it.
///
/// Look (darkness, blur preset, fade speed) comes from `SpotlightConfig` via
/// `apply(config:)`.
///
/// Darkening comes from `tintView` (plain black at `config.darkness`
/// opacity); blurring comes from `blurView`, an `NSVisualEffectView` in
/// `.behindWindow` blending mode, which samples and blurs whatever is
/// actually on screen underneath this window. Both get their own
/// `CAShapeLayer` mask (same path, kept in sync) rather than one shared mask
/// on a wrapping container — that avoids relying on whether a mask set on an
/// ancestor layer correctly propagates through `NSVisualEffectView`'s
/// internal backdrop-filter layer.
///
/// `updateHoles(excludedFrames:)` merges its rects via
/// `RectMerging.mergingOverlapping` — see that type's doc comment for why
/// overlapping holes must be pre-merged before cutting an even-odd mask.
final class SpotlightOverlayWindow: NSPanel {
    /// Fade durations at `speed == 1`; actual duration is `base / speed`.
    static let baseShowAnimationDuration: TimeInterval = 0.35
    static let baseHideAnimationDuration: TimeInterval = 0.15

    private var speed: Double = SpotlightConfig.defaultSpeed
    private var showAnimationDuration: TimeInterval { Self.baseShowAnimationDuration / speed }
    /// Un-dimming is always the same quick fade, independent of the fade-speed setting.
    private var hideAnimationDuration: TimeInterval { Self.baseHideAnimationDuration }

    private let blurView = NSVisualEffectView()
    private let tintView = NSView()
    private let blurMask = CAShapeLayer()
    private let tintMask = CAShapeLayer()

    init(screen: NSScreen) {
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
        // a real window tile; scoped to the space it was created on (no
        // `.canJoinAllSpaces`) — Spotlight is deliberately windowed-desktop
        // only, not a full-screen-Space feature.
        collectionBehavior = [.stationary, .ignoresCycle]
        alphaValue = 0

        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.mask = blurMask

        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(SpotlightConfig.defaultDarkness).cgColor
        tintView.layer?.mask = tintMask

        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blurView.frame = container.bounds
        blurView.autoresizingMask = [.width, .height]
        tintView.frame = container.bounds
        tintView.autoresizingMask = [.width, .height]
        container.addSubview(blurView)
        container.addSubview(tintView)
        self.contentView = container

        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Pushes the user-tunable look into the views. Safe to call while shown —
    /// it only changes layer/material properties, not visibility.
    func apply(config: SpotlightConfig) {
        speed = min(max(config.speed, SpotlightConfig.minSpeed), SpotlightConfig.maxSpeed)
        SpotlightLook.apply(blurView: blurView, tintView: tintView, darkness: config.darkness, blur: config.blurPreset)
    }

    /// `excludedFrames` are in the global NS screen-coordinate system
    /// (bottom-left origin, matching `NSScreen.frame`) — same convention as
    /// `AXWindow.frame` everywhere else in this codebase. Converts to this
    /// window's own local coordinates (origin at this screen's bottom-left),
    /// which — since neither `blurView`/`tintView` override `isFlipped` —
    /// needs only a translation, no vertical flip.
    func updateHoles(excludedFrames: [CGRect], screenFrame: CGRect, animated: Bool = false) {
        let merged = RectMerging.mergingOverlapping(excludedFrames)
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: screenFrame.size))
        for frame in merged {
            let clipped = frame.intersection(screenFrame)
            guard !clipped.isEmpty else { continue }
            let local = CGRect(
                x: clipped.minX - screenFrame.minX,
                y: clipped.minY - screenFrame.minY,
                width: clipped.width,
                height: clipped.height
            )
            path.addRect(local)
        }
        for mask in [blurMask, tintMask] {
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

/// Maps the user's darkness + blur-preset choices onto a blur/tint view pair.
/// Shared by the full-screen overlay and the browser top-bar panel, which have
/// independent settings but identical machinery.
enum SpotlightLook {
    static func apply(blurView: NSVisualEffectView, tintView: NSView, darkness: Double, blur: SpotlightBlurPreset) {
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(min(max(darkness, 0), 1)).cgColor
        // The system blur materials all blur about equally hard, so the weaker
        // levels fade the blur view itself: a partial-opacity blur is a mix of
        // sharp and blurred, i.e. a gentler blur.
        blurView.material = .hudWindow
        switch blur {
        case .off:
            blurView.isHidden = true
        case .light:
            blurView.isHidden = false
            blurView.alphaValue = 0.25
        case .medium:
            blurView.isHidden = false
            blurView.alphaValue = 0.55
        case .heavy:
            blurView.isHidden = false
            blurView.alphaValue = 1
        }
    }
}
