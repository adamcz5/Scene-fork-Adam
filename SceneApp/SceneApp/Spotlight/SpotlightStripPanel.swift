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
    private static let bandCount = 6
    static let edgePointsPerLevel: CGFloat = 8

    private let tintView = NSView()
    private let topScale: CGFloat
    private let bottomScale: CGFloat
    private var bands: [SpotlightStripPanel] = []
    private let isBand: Bool
    private let isHelper: Bool
    /// Two extra blur-only panels laid exactly over the bar. Stacked backdrop
    /// blurs compound like Gaussians (radii combine as sqrt(a² + b² + c²)), so
    /// three whole-number radii can make many more in-between strengths than one
    /// — that is what keeps a SMALL blur (e.g. Lite) from arriving in 3-4 jumps.
    private var blurHelpers: [SpotlightStripPanel] = []
    private static let composeMaxRadius: Double = 8
    private var lastBlurInt: Int = -1
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
        blurHelpers = (0..<2).map { _ in SpotlightStripPanel(frame: frame, topScale: 1, bottomScale: 1, isHelper: true) }
        guard feather > 0 else { return }
        let count: Int = Self.bandCount
        let total = CGFloat(count)
        let bandHeight: CGFloat = feather / total
        var made: [SpotlightStripPanel] = []
        for i in 0..<count {
            let index = CGFloat(i)
            let bandFrame = CGRect(
                x: frame.minX,
                y: frame.minY - (index + 1) * bandHeight,
                width: frame.width,
                height: bandHeight
            )
            let top: CGFloat = 1 - index / total
            let bottom: CGFloat = 1 - (index + 1) / total
            made.append(SpotlightStripPanel(frame: bandFrame, topScale: top, bottomScale: bottom))
        }
        bands = made
    }

    private init(frame: CGRect, topScale: CGFloat, bottomScale: CGFloat, isHelper: Bool = false) {
        self.topScale = topScale
        self.bottomScale = bottomScale
        self.isBand = topScale != 1 || bottomScale != 1
        self.isHelper = isHelper
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
        if !isBand && !isHelper { addSideShading(to: tintView) }
        contentView = tintView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The outermost few percent on the left and right edges get a little extra
    /// darkness (same blur), easing in smoothly, so the bar blends into a dark,
    /// blurred background. The middle stays at constant darkness.
    private static let sideShadeFraction: CGFloat = 0.03
    /// At the very edge the bar is this much darker than the middle, in
    /// proportion (1.3 = 30% darker), so it tracks the darkness slider.
    private static let sideShadeRatio: CGFloat = 1.3
    private static let sideShadeCap: CGFloat = 0.95
    private var sideShade: CAGradientLayer?
    private static let sideShadeFactors: [CGFloat] = [1, 0.74, 0.26, 0, 0, 0.26, 0.74, 1]

    private func addSideShading(to view: NSView) {
        let width = Self.sideShadeFraction
        let gradient = CAGradientLayer()
        gradient.frame = view.bounds
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        let third: CGFloat = width / 3
        let stops: [CGFloat] = [0, third, third * 2, width, 1 - width, 1 - third * 2, 1 - third, 1]
        var locations: [NSNumber] = []
        for stop in stops { locations.append(NSNumber(value: Double(stop))) }
        gradient.locations = locations
        view.layer?.addSublayer(gradient)
        sideShade = gradient
        updateSideShade(darkness: SpotlightConfig.defaultChromeDarkness * SpotlightConfig.chromeAlphaPerLevel)
    }

    /// Extra black on top of the bar's tint so the total at the edge is
    /// `darkness * ratio` (capped): d + e(1 - d) = target  =>  e = (target - d) / (1 - d).
    private func updateSideShade(darkness: Double) {
        guard let sideShade else { return }
        let d = CGFloat(min(max(darkness, 0), 1))
        let target = min(d * Self.sideShadeRatio, Self.sideShadeCap)
        let extra: CGFloat = (d < 1 && target > d) ? (target - d) / (1 - d) : 0
        var colors: [CGColor] = []
        for factor in Self.sideShadeFactors {
            colors.append(NSColor.black.withAlphaComponent(extra * factor).cgColor)
        }
        sideShade.colors = colors
    }

    private var midScale: Double { Double(topScale + bottomScale) / 2 }

    func apply(config: SpotlightConfig, animated: Bool = false) {
        if isHelper { return }
        speed = min(max(config.browserChromeSpeed, SpotlightConfig.minSpeed), SpotlightConfig.maxSpeed)
        returnDelay = max(config.browserChromeDelaySeconds, 0)
        let darkness = min(max(config.effectiveChromeDarkness, 0), 1)
        updateSideShade(darkness: darkness)
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
        for band in bands { band.apply(config: config, animated: animated) }
        // Bands never drive the blur themselves: the bar's panel pushes one
        // shared radius to every band (scaled), so there is a single timer.
        guard !isBand else { return }
        targetBlur = min(max(config.effectiveChromeBlurRadius, 0), SpotlightConfig.maxChromeBlurRadius)
        if shown && !hovered {
            if animated { glideBlur() } else { setBlur(targetBlur) }
        }
    }

    func show(quick: Bool = false) {
        shown = true
        orderFrontRegardless()
        let fade = quick ? Self.baseHideDuration : Self.baseShowDuration / speed
        // The blur isn't part of the window's opacity fade, so it is ramped by
        // hand over the same time and with the same ease-in/ease-out curve.
        if !isBand, !hovered { glideBlur(from: 0, duration: fade) }
        animate(to: hovered ? 0 : 1, duration: fade, timing: .easeInEaseOut)
        for helper in blurHelpers {
            helper.alphaValue = 1
            helper.orderFrontRegardless()
        }
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
            for helper in blurHelpers { helper.orderOut(nil) }
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
            for helper in self.blurHelpers { helper.orderOut(nil) }
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
        let fade = Self.baseShowDuration / speed
        if !isBand { glideBlur(from: 0, duration: fade) }
        animate(to: 1, duration: fade, timing: .easeInEaseOut)
    }

    // MARK: - Blur

    /// Sets this panel's blur (scaled for bands) and every band's, skipping the
    /// window-server call when the whole-number radius hasn't changed.
    private func pushBlur(_ radius: Double) {
        displayedBlur = radius
        var main = Int((radius * (isBand ? midScale : 1)).rounded())
        var extra = [0, 0]
        if !isBand, !blurHelpers.isEmpty, targetBlur <= Self.composeMaxRadius {
            let best = Self.composedRadii(for: radius, maxRadius: Int(targetBlur.rounded(.up)))
            main = best.0
            extra = [best.1, best.2]
        }
        setWholeBlur(main)
        for (helper, value) in zip(blurHelpers, extra) { helper.setWholeBlur(value) }
        for band in bands { band.pushBlur(radius) }
    }

    private func setWholeBlur(_ value: Int) {
        guard value != lastBlurInt else { return }
        lastBlurInt = value
        WindowBackgroundBlur.set(radius: value, for: self)
    }

    /// The whole-number triple (a >= b >= c) whose combined blur
    /// sqrt(a² + b² + c²) is closest to `radius`.
    private static func composedRadii(for radius: Double, maxRadius: Int) -> (Int, Int, Int) {
        var best: (Int, Int, Int) = (0, 0, 0)
        var bestError = Double.greatestFiniteMagnitude
        var bestSum = Int.max
        let top = max(maxRadius, 0)
        for a in 0...top {
            for b in 0...a {
                for c in 0...b {
                    let combined = (Double(a * a + b * b + c * c)).squareRoot()
                    let error = abs(combined - radius)
                    let sum = a + b + c
                    if error < bestError - 0.0001 || (abs(error - bestError) <= 0.0001 && sum < bestSum) {
                        best = (a, b, c)
                        bestError = error
                        bestSum = sum
                    }
                }
            }
        }
        return best
    }

    private func setBlur(_ radius: Double) {
        blurTimer?.invalidate()
        blurTimer = nil
        pushBlur(radius)
    }

    private func clearBlur() {
        blurTimer?.invalidate()
        blurTimer = nil
        pushBlur(0)
    }

    /// The window-background blur call has no animation of its own, so the
    /// radius is stepped by hand — linearly, because the radius only takes
    /// whole numbers and a small blur has just a few steps to spread out.
    private func glideBlur(from startRadius: Double? = nil, duration: TimeInterval = SpotlightStripPanel.liveChangeDuration) {
        blurTimer?.invalidate()
        let start = startRadius ?? displayedBlur
        pushBlur(start)
        let end = targetBlur
        guard start != end else { return }
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let progress = min(Date().timeIntervalSince(began) / max(duration, 0.01), 1)
            self.pushBlur(start + (end - start) * progress)
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
