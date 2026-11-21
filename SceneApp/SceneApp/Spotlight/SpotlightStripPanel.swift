import AppKit
import QuartzCore
import SceneCore

/// A small click-through panel laid over a browser's top bar (tabs, address
/// bar, bookmarks) that dims it with its OWN darkness and blur — separate from
/// the full-screen dim so it can be darker and far sharper — and that fades away
/// while the mouse is over it, so the bar is usable on demand.
///
/// Soft bottom edge: with `feather > 0` the panel also owns a few thin "band"
/// panels directly below the bar. Each band's tint fades along a gradient and
/// its blur radius steps down, so both darkness and blur ease out into the page
/// instead of ending on a hard line. All show/hide/hover calls fan out to them.
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
    private static let liveChangeDuration: TimeInterval = 0.3
    private static let bandCount = 4
    static let edgePointsPerLevel: CGFloat = 4

    private let tintView = NSView()
    private let topScale: CGFloat
    private let bottomScale: CGFloat
    private var bands: [SpotlightStripPanel] = []
    private var speed: Double = SpotlightConfig.defaultSpeed
    /// Blur radius this panel should have when fully shown (already scaled for bands).
    private var targetBlur: Double = 0
    private var displayedBlur: Double = 0
    private var blurTimer: Timer?
    private var hovered = false
    private var shown = false
    private var returnTimer: Timer?
    /// After the pointer leaves, the bar stays clear for the top bar's own
    /// Fade delay, then fades back at its own Fade speed (both from Settings).
    private var returnDelay: TimeInterval = SpotlightConfig.defaultIdleDelaySeconds

    /// The bar itself, plus (when `feather > 0`) soft-edge bands below it.
    convenience init(frame: CGRect, feather: CGFloat) {
        self.init(frame: frame, topScale: 1, bottomScale: 1)
        guard feather > 0 else { return }
        let count = Self.bandCount
        let bandHeight = feather / CGFloat(count)
        bands = (0..<count).map { i in
            SpotlightStripPanel(
                frame: CGRect(x: frame.minX, y: frame.minY - CGFloat(i + 1) * bandHeight,
                              width: frame.width, height: bandHeight),
                topScale: 1 - CGFloat(i) / CGFloat(count),
                bottomScale: 1 - CGFloat(i + 1) / CGFloat(count)
            )
        }
    }

    private init(frame: CGRect, topScale: CGFloat, bottomScale: CGFloat) {
        self.topScale = topScale
        self.bottomScale = bottomScale
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
        if topScale != 1 || bottomScale != 1 {
            // Tint opacity ramps from `topScale` at the top of this band to
            // `bottomScale` at its bottom (view space is bottom-left origin).
            let gradient = CAGradientLayer()
            gradient.frame = tintView.bounds
            gradient.colors = [NSColor.white.withAlphaComponent(topScale).cgColor,
                               NSColor.white.withAlphaComponent(bottomScale).cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            tintView.layer?.mask = gradient
        }
        contentView = tintView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var midScale: Double { Double(topScale + bottomScale) / 2 }

    func apply(config: SpotlightConfig, animated: Bool = false) {
        speed = min(max(config.browserChromeSpeed, SpotlightConfig.minSpeed), SpotlightConfig.maxSpeed)
        returnDelay = max(config.browserChromeDelaySeconds, 0)
        let darkness = min(max(config.effectiveChromeDarkness, 0), 1)
        let color = NSColor.black.withAlphaComponent(darkness).cgColor
        if animated, let layer = tintView.layer {
            let anim = CABasicAnimation(keyPath: "backgroundColor")
            anim.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            anim.toValue = color
            anim.duration = Self.liveChangeDuration
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "liveTint")
            layer.backgroundColor = color
        } else {
            tintView.layer?.backgroundColor = color
        }
        targetBlur = min(max(config.effectiveChromeBlurRadius, 0), SpotlightConfig.maxChromeBlurRadius) * midScale
        if shown && !hovered {
            if animated { glideBlur() } else { setBlur(targetBlur) }
        }
        for band in bands { band.apply(config: config, animated: animated) }
    }

    func show(quick: Bool = false) {
        shown = true
        orderFrontRegardless()
        if !hovered { setBlur(targetBlur) }
        animate(to: hovered ? 0 : 1, duration: quick ? Self.baseHideDuration : Self.baseShowDuration / speed, timing: .easeOut)
        for band in bands { band.show(quick: quick) }
    }

    /// Fades out and orders out; `immediate` skips the fade.
    func hide(immediate: Bool = false) {
        shown = false
        returnTimer?.invalidate()
        returnTimer = nil
        hovered = false
        blurTimer?.invalidate()
        blurTimer = nil
        for band in bands { band.hide(immediate: immediate) }
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
        for band in bands { band.setHovered(isHovered) }
        if isHovered {
            returnTimer?.invalidate()
            returnTimer = nil
            guard !hovered else { return }
            hovered = true
            guard shown else { return }
            blurTimer?.invalidate()
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
        setBlur(targetBlur)
        animate(to: 1, duration: Self.baseShowDuration / speed, timing: .easeInEaseOut)
    }

    // MARK: - Blur

    private func setBlur(_ radius: Double) {
        blurTimer?.invalidate()
        blurTimer = nil
        displayedBlur = radius
        WindowBackgroundBlur.set(radius: Int(radius.rounded()), for: self)
    }

    private func clearBlur() {
        blurTimer?.invalidate()
        blurTimer = nil
        displayedBlur = 0
        WindowBackgroundBlur.set(radius: 0, for: self)
    }

    /// The window-background blur call has no animation of its own, so a live
    /// change steps the radius by hand from where it is to the new value.
    private func glideBlur() {
        blurTimer?.invalidate()
        let start = displayedBlur
        let end = targetBlur
        guard start != end else { return }
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let progress = min(Date().timeIntervalSince(began) / Self.liveChangeDuration, 1)
            let eased = progress * progress * (3 - 2 * progress)
            self.displayedBlur = start + (end - start) * eased
            WindowBackgroundBlur.set(radius: Int(self.displayedBlur.rounded()), for: self)
            if progress >= 1 { t.invalidate(); self.blurTimer = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        blurTimer = timer
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
