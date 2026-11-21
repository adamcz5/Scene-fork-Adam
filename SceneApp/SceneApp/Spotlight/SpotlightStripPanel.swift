import AppKit
import SceneCore

/// A small click-through panel laid over a browser's top bar (tabs, address
/// bar, bookmarks) that dims it with its OWN darkness and blur — separate from
/// the full-screen dim so it can be darker and far sharper — and that fades away
/// while the mouse is over it, so the bar is usable on demand.
///
/// The blur is a continuous radius (`WindowBackgroundBlur`), not an
/// `NSVisualEffectView` material: the system materials only come in fixed,
/// very strong strengths, which turned the tabs into mush.
///
/// It can't use a tracking area to notice the mouse because it ignores mouse
/// events (clicks must reach the browser underneath), so `SpotlightController`
/// polls the pointer position and calls `setHovered(_:)`.
final class SpotlightStripPanel: NSPanel {
    private static let baseShowDuration: TimeInterval = 0.35
    private static let baseHideDuration: TimeInterval = 0.15
    private static let hoverDuration: TimeInterval = 0.12

    private let tintView = NSView()
    private var speed: Double = SpotlightConfig.defaultSpeed
    private var blurRadius: Int = 0
    private var hovered = false
    private var returnTimer: Timer?
    /// After the pointer leaves, the bar stays clear for the top bar's own
    /// Fade delay, then fades back at its own Fade speed (both from Settings).
    private var returnDelay: TimeInterval = SpotlightConfig.defaultIdleDelaySeconds
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

        tintView.wantsLayer = true
        tintView.frame = NSRect(origin: .zero, size: frame.size)
        tintView.autoresizingMask = [.width, .height]
        contentView = tintView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func apply(config: SpotlightConfig) {
        speed = min(max(config.browserChromeSpeed, SpotlightConfig.minSpeed), SpotlightConfig.maxSpeed)
        returnDelay = max(config.browserChromeDelaySeconds, 0)
        let darkness = min(max(config.effectiveChromeDarkness, 0), 1)
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(darkness).cgColor
        blurRadius = Int(min(max(config.effectiveChromeBlurRadius, 0), SpotlightConfig.maxChromeBlurRadius).rounded())
        if shown && !hovered { applyBlur() }
    }

    func show(quick: Bool = false) {
        shown = true
        orderFrontRegardless()
        if !hovered { applyBlur() }
        animate(to: hovered ? 0 : 1, duration: quick ? Self.baseHideDuration : Self.baseShowDuration / speed, timing: .easeOut)
    }

    /// Fades out and orders out; `immediate` skips the fade.
    func hide(immediate: Bool = false) {
        shown = false
        returnTimer?.invalidate()
        returnTimer = nil
        hovered = false
        if immediate {
            alphaValue = 0
            clearBlur()
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.baseHideDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // A later `show()` during the fade re-raises alpha first; only
            // order out if we're still actually hidden.
            guard let self, !self.shown else { return }
            self.clearBlur()
            self.orderOut(nil)
        })
    }

    /// Pointer is over (or left) the strip: clear it out of the way / bring it
    /// back. The blur is switched off immediately rather than faded, since the
    /// window-background blur doesn't follow the window's alpha.
    func setHovered(_ isHovered: Bool) {
        if isHovered {
            returnTimer?.invalidate()
            returnTimer = nil
            guard !hovered else { return }
            hovered = true
            guard shown else { return }
            clearBlur()
            animate(to: 0, duration: Self.hoverDuration, timing: .easeInEaseOut)
        } else {
            // Pointer left: keep the bar clear for a moment before dimming again.
            guard hovered, returnTimer == nil else { return }
            returnTimer = Timer.scheduledTimer(withTimeInterval: returnDelay, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finishHover() }
            }
        }
    }

    private func finishHover() {
        returnTimer = nil
        hovered = false
        guard shown else { return }
        applyBlur()
        animate(to: 1, duration: Self.baseShowDuration / speed, timing: .easeInEaseOut)
    }

    private func applyBlur() {
        WindowBackgroundBlur.set(radius: blurRadius, for: self)
    }

    private func clearBlur() {
        WindowBackgroundBlur.set(radius: 0, for: self)
    }

    private func animate(to alpha: CGFloat, duration: TimeInterval, timing: CAMediaTimingFunctionName) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: timing)
            animator().alphaValue = alpha
        }
    }
}

/// Continuous-radius blur of whatever is behind a transparent window, via the
/// window server's background-blur call (what terminal apps use for a blur
/// slider). It is private API, so it is looked up at runtime: if it's missing
/// or changes, the call quietly does nothing and the window just shows its
/// tint — never a crash or a link failure.
enum WindowBackgroundBlur {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetBlurRadius = @convention(c) (Int32, Int32, Int32) -> Int32

    /// `RTLD_DEFAULT`, which Swift doesn't import: search every loaded image.
    private static let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)

    private static let connection: DefaultConnection? = {
        guard let symbol = dlsym(defaultHandle, "CGSDefaultConnectionForThread") else { return nil }
        return unsafeBitCast(symbol, to: DefaultConnection.self)
    }()

    private static let setRadius: SetBlurRadius? = {
        guard let symbol = dlsym(defaultHandle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return unsafeBitCast(symbol, to: SetBlurRadius.self)
    }()

    static func set(radius: Int, for window: NSWindow) {
        guard window.windowNumber > 0, let connection, let setRadius else { return }
        _ = setRadius(connection(), Int32(window.windowNumber), Int32(max(radius, 0)))
    }
}
