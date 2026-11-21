import AppKit
import SceneCore

/// A small click-through panel laid over a browser's top bar (tabs, address
/// bar, bookmarks) that dims it with its OWN darkness and blur — separate from
/// the full-screen dim so it can be darker and sharper — and that fades away
/// while the mouse is over it, so the bar is usable on demand.
///
/// It can't use a tracking area to notice the mouse because it ignores mouse
/// events (clicks must reach the browser underneath), so `SpotlightController`
/// polls the pointer position and calls `setHovered(_:)`.
final class SpotlightStripPanel: NSPanel {
    private static let baseShowDuration: TimeInterval = 0.35
    private static let baseHideDuration: TimeInterval = 0.15
    private static let hoverDuration: TimeInterval = 0.12

    private let blurView = NSVisualEffectView()
    private let tintView = NSView()
    private var speed: Double = SpotlightConfig.defaultSpeed
    private var hovered = false
    private var shown = false

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
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
        ignoresMouseEvents = true
        isMovableByWindowBackground = false
        collectionBehavior = [.stationary, .ignoresCycle]
        alphaValue = 0

        blurView.blendingMode = .behindWindow
        blurView.state = .active
        tintView.wantsLayer = true

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        for view in [blurView, tintView] {
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
        }
        contentView = container
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(config: SpotlightConfig) {
        speed = min(max(config.speed, SpotlightConfig.minSpeed), SpotlightConfig.maxSpeed)
        SpotlightLook.apply(
            blurView: blurView, tintView: tintView,
            darkness: config.browserChromeDarkness, blur: config.browserChromeBlur
        )
    }

    func show() {
        shown = true
        orderFrontRegardless()
        animate(to: hovered ? 0 : 1, duration: Self.baseShowDuration / speed, timing: .easeOut)
    }

    /// Fades out and orders out; `immediate` skips the fade.
    func hide(immediate: Bool = false) {
        shown = false
        if immediate {
            alphaValue = 0
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.baseHideDuration / speed
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A later `show()` during the fade re-raises alpha first; only
            // order out if we're still actually hidden.
            guard let self, !self.shown else { return }
            self.orderOut(nil)
        })
    }

    /// Pointer is over (or left) the strip: fade it out of the way / back in.
    func setHovered(_ isHovered: Bool) {
        guard isHovered != hovered else { return }
        hovered = isHovered
        guard shown else { return }
        animate(to: isHovered ? 0 : 1, duration: Self.hoverDuration, timing: .easeInEaseOut)
    }

    private func animate(to alpha: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunctionName) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: timing)
            animator().alphaValue = alpha
        }
    }
}
