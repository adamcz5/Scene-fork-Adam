import AppKit
import QuartzCore
import SceneCore

/// One borderless, click-through, non-activating panel per `NSScreen` that
/// darkens + blurs the whole screen except the rect(s) punched out of it.
///
/// Visual strength is intentionally hardcoded (see `tintAlpha` / the blur
/// `material`) — only behavior (on/off, scope, idle delay) is user-tunable,
/// via `SpotlightConfig`.
///
/// Darkening comes from `tintView` (plain black, `tintAlpha` opacity);
/// blurring comes from `blurView`, an `NSVisualEffectView` in `.behindWindow`
/// blending mode, which samples and blurs whatever is actually on screen
/// underneath this window. Both get their own `CAShapeLayer` mask (same path,
/// kept in sync) rather than one shared mask on a wrapping container — that
/// avoids relying on whether a mask set on an ancestor layer correctly
/// propagates through `NSVisualEffectView`'s internal backdrop-filter layer.
///
/// `updateHoles(excludedFrames:)` expects rects already merged via
/// `RectMerging.mergingOverlapping` — see that type's doc comment for why
/// overlapping holes must be pre-merged before cutting an even-odd mask.
final class SpotlightOverlayWindow: NSPanel {
    static let tintAlpha: CGFloat = 0.45
    static let showAnimationDuration: TimeInterval = 0.35
    static let hideAnimationDuration: TimeInterval = 0.15

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
        tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(Self.tintAlpha).cgColor
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

    /// `excludedFrames` are in the global NS screen-coordinate system
    /// (bottom-left origin, matching `NSScreen.frame`) — same convention as
    /// `AXWindow.frame` everywhere else in this codebase. Converts to this
    /// window's own local coordinates (origin at this screen's bottom-left),
    /// which — since neither `blurView`/`tintView` override `isFlipped` —
    /// needs only a translation, no vertical flip.
    func updateHoles(excludedFrames: [CGRect], screenFrame: CGRect) {
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
        blurMask.path = path
        blurMask.fillRule = .evenOdd
        tintMask.path = path
        tintMask.fillRule = .evenOdd
    }

    func show() {
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.showAnimationDuration
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
            ctx.duration = Self.hideAnimationDuration
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
