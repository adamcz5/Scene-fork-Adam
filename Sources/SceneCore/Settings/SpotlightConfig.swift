import Foundation

/// How many exclusion targets Spotlight keeps undimmed at once, relevant
/// only when more than one display is connected.
public enum SpotlightExclusionMode: String, Codable, CaseIterable, Sendable {
    /// One exclusion target total — the single system-wide frontmost
    /// window. Every OTHER screen dims completely, even where that screen's
    /// own last-active window sits.
    case single
    /// One exclusion target PER screen — each monitor keeps its own most
    /// recently active window undimmed, independent of which monitor
    /// currently holds the system-wide frontmost window. E.g. Slack stays
    /// undimmed on monitor 1 while you're focused on Chrome on monitor 2.
    case perMonitor
}

/// How strongly the dimmed area is blurred. The system blur view
/// (`NSVisualEffectView`) only offers a handful of fixed materials, not a
/// continuous radius, so this is a short list of presets rather than a slider.
public enum SpotlightBlurPreset: String, Codable, CaseIterable, Sendable {
    case off
    case light
    case heavy
}

/// How the browser's own top bar (tabs, address bar, bookmarks) is found when
/// `SpotlightConfig.dimBrowserChrome` is on.
public enum SpotlightChromeMode: String, Codable, CaseIterable, Sendable {
    /// Ask the browser (via accessibility) where the page itself is; everything
    /// above it in the window is the top bar. Adapts to a bookmarks bar being
    /// shown or hidden, but depends on the browser exposing that information.
    case automatic
    /// Dim a fixed number of points down from the top of the window. Always
    /// works, but doesn't adapt if the toolbars change height.
    case fixedHeight
}

/// User-tunable settings for "Spotlight" — a dim+blur overlay that darkens
/// everything except the window you're currently working in.
///
/// Deliberately not named `FocusMode`: that name is already taken in this
/// codebase by `Workspace.focusMode` / `FocusModeReference`, which invokes a
/// macOS Focus (Do Not Disturb) Shortcut on Workspace activation — a
/// completely different feature. Spotlight has nothing to do with macOS
/// Focus and nothing to do with Workspaces; it's a standalone, always-on
/// (when enabled) overlay driven purely by which window is frontmost.
public struct SpotlightConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var exclusionMode: SpotlightExclusionMode
    /// Seconds of no app/window switch before the overlay fades in. Clamped
    /// to `[minIdleDelaySeconds, maxIdleDelaySeconds]` by the Settings slider;
    /// stored as-is here so a value from a future wider range still round-trips.
    public var idleDelaySeconds: Double
    /// Opacity of the black tint over the dimmed area, `0...1`.
    public var darkness: Double
    public var blurPreset: SpotlightBlurPreset
    /// Multiplier on the fade in/out speed: `1` is the default pace, higher is
    /// faster, lower is slower. Clamped to `[minSpeed, maxSpeed]` by the slider.
    public var speed: Double
    /// Global hotkey that flips `enabled`. Everything else (including
    /// `exclusionMode`) is left exactly as it was, so toggling back on
    /// restores the previous behavior.
    public var hotkey: HotkeyBinding?
    /// EXPERIMENTAL (default off): also re-darken a browser's own tab
    /// strip/toolbar/bookmark bar inside an otherwise-undimmed window. See
    /// `BrowserChromeDetector` in SceneApp for the heuristic and its limits —
    /// this is best-effort and silently does nothing for browsers/windows it
    /// doesn't recognize.
    public var dimBrowserChrome: Bool
    public var browserChromeMode: SpotlightChromeMode
    /// Height in points of the dimmed top strip in `.fixedHeight` mode.
    public var browserChromeHeight: Double
    /// The top bar is dimmed by its own layer, separate from the main dim, so
    /// it can be darker and less blurred (blurring tabs makes them unreadable
    /// well before they're hidden enough).
    public var browserChromeDarkness: Double
    /// Blur radius behind the top bar, in points; `0` is no blur. A radius
    /// rather than the off/light/heavy presets the full-screen dim uses: the
    /// system's blur materials only come in fixed, strong strengths, far too
    /// heavy for tabs you still want to half-read.
    public var browserChromeBlurRadius: Double
    /// Apps (bundle IDs) whose windows are never dimmed, even when they aren't
    /// the frontmost app — e.g. keep a chat window readable while working in
    /// a browser. Chosen manually in Settings.
    public var exceptionBundleIDs: [String]
    /// "Light" variant of the top-bar dim, picked from the menu bar's Tabs tile
    /// (Off → On → Light). Uses its own, gentler darkness and blur.
    public var browserChromeLight: Bool
    public var browserChromeLightDarkness: Double
    public var browserChromeLightBlurRadius: Double
    public static let defaultChromeLightDarkness: Double = 0.4
    public static let defaultChromeLightBlurRadius: Double = 5
    /// Darkness / blur actually used for the top bar right now.
    public var effectiveChromeDarkness: Double { browserChromeLight ? browserChromeLightDarkness : browserChromeDarkness }
    public var effectiveChromeBlurRadius: Double { browserChromeLight ? browserChromeLightBlurRadius : browserChromeBlurRadius }
    public static let maxChromeBlurRadius: Double = 20
    public static let defaultChromeBlurRadius: Double = 3
    /// Global hotkey that flips `dimBrowserChrome` — separate from `hotkey`,
    /// which toggles Dim as a whole.
    public var browserChromeHotkey: HotkeyBinding?

    public static let defaultChromeDarkness: Double = 0.55
    public static let minChromeHeight: Double = 40
    public static let maxChromeHeight: Double = 220
    public static let defaultChromeHeight: Double = 90

    public static let minIdleDelaySeconds: Double = 1
    public static let maxIdleDelaySeconds: Double = 8
    public static let defaultIdleDelaySeconds: Double = 2.5

    public static let minDarkness: Double = 0.2
    public static let maxDarkness: Double = 0.9
    public static let defaultDarkness: Double = 0.45

    public static let minSpeed: Double = 0.1
    public static let maxSpeed: Double = 3
    public static let defaultSpeed: Double = 1

    /// `enabled: false` by default — this changes what's visually on screen
    /// at all times once on, so it should be an explicit opt-in rather than
    /// surprising a user who just upgraded.
    public static let `default` = SpotlightConfig()

    public init(
        enabled: Bool = false,
        exclusionMode: SpotlightExclusionMode = .single,
        idleDelaySeconds: Double = SpotlightConfig.defaultIdleDelaySeconds,
        darkness: Double = SpotlightConfig.defaultDarkness,
        blurPreset: SpotlightBlurPreset = .heavy,
        speed: Double = SpotlightConfig.defaultSpeed,
        hotkey: HotkeyBinding? = nil,
        dimBrowserChrome: Bool = false,
        browserChromeMode: SpotlightChromeMode = .automatic,
        browserChromeHeight: Double = SpotlightConfig.defaultChromeHeight,
        browserChromeDarkness: Double = SpotlightConfig.defaultChromeDarkness,
        browserChromeBlurRadius: Double = SpotlightConfig.defaultChromeBlurRadius,
        browserChromeHotkey: HotkeyBinding? = nil,
        exceptionBundleIDs: [String] = [],
        browserChromeLight: Bool = false,
        browserChromeLightDarkness: Double = SpotlightConfig.defaultChromeLightDarkness,
        browserChromeLightBlurRadius: Double = SpotlightConfig.defaultChromeLightBlurRadius
    ) {
        self.enabled = enabled
        self.exclusionMode = exclusionMode
        self.idleDelaySeconds = idleDelaySeconds
        self.darkness = darkness
        self.blurPreset = blurPreset
        self.speed = speed
        self.hotkey = hotkey
        self.dimBrowserChrome = dimBrowserChrome
        self.browserChromeMode = browserChromeMode
        self.browserChromeHeight = browserChromeHeight
        self.browserChromeDarkness = browserChromeDarkness
        self.browserChromeBlurRadius = browserChromeBlurRadius
        self.browserChromeHotkey = browserChromeHotkey
        self.exceptionBundleIDs = exceptionBundleIDs
        self.browserChromeLight = browserChromeLight
        self.browserChromeLightDarkness = browserChromeLightDarkness
        self.browserChromeLightBlurRadius = browserChromeLightBlurRadius
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, exclusionMode, idleDelaySeconds, darkness, blurPreset, speed, hotkey, dimBrowserChrome
        case browserChromeMode, browserChromeHeight
        // These two shipped once with defaults (0.6 / light blur) that looked
        // heavier than the main dim; new storage keys make every install pick
        // up the corrected defaults instead of keeping the saved old ones.
        case browserChromeDarkness = "browserChromeTint"
        case browserChromeBlurRadius
        case browserChromeHotkey
        case exceptionBundleIDs
        case browserChromeLight, browserChromeLightDarkness, browserChromeLightBlurRadius
    }

    /// Every field decodes with a fallback so a partially-written file (crash
    /// mid-write, hand edit, or an older build's file missing a field added
    /// later) degrades to defaults field-by-field instead of failing the
    /// whole decode. Unknown keys from older builds (e.g. the removed
    /// `scope`) are simply ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.exclusionMode = try c.decodeIfPresent(SpotlightExclusionMode.self, forKey: .exclusionMode) ?? .single
        self.idleDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .idleDelaySeconds) ?? Self.defaultIdleDelaySeconds
        self.darkness = try c.decodeIfPresent(Double.self, forKey: .darkness) ?? Self.defaultDarkness
        self.blurPreset = try c.decodeIfPresent(SpotlightBlurPreset.self, forKey: .blurPreset) ?? .heavy
        self.speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? Self.defaultSpeed
        self.hotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .hotkey)
        self.dimBrowserChrome = try c.decodeIfPresent(Bool.self, forKey: .dimBrowserChrome) ?? false
        self.browserChromeMode = try c.decodeIfPresent(SpotlightChromeMode.self, forKey: .browserChromeMode) ?? .automatic
        self.browserChromeHeight = try c.decodeIfPresent(Double.self, forKey: .browserChromeHeight) ?? Self.defaultChromeHeight
        self.browserChromeDarkness = try c.decodeIfPresent(Double.self, forKey: .browserChromeDarkness) ?? Self.defaultChromeDarkness
        self.browserChromeBlurRadius = try c.decodeIfPresent(Double.self, forKey: .browserChromeBlurRadius) ?? Self.defaultChromeBlurRadius
        self.browserChromeHotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .browserChromeHotkey)
        self.exceptionBundleIDs = try c.decodeIfPresent([String].self, forKey: .exceptionBundleIDs) ?? []
        self.browserChromeLight = try c.decodeIfPresent(Bool.self, forKey: .browserChromeLight) ?? false
        self.browserChromeLightDarkness = try c.decodeIfPresent(Double.self, forKey: .browserChromeLightDarkness) ?? Self.defaultChromeLightDarkness
        self.browserChromeLightBlurRadius = try c.decodeIfPresent(Double.self, forKey: .browserChromeLightBlurRadius) ?? Self.defaultChromeLightBlurRadius
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(exclusionMode, forKey: .exclusionMode)
        try c.encode(idleDelaySeconds, forKey: .idleDelaySeconds)
        try c.encode(darkness, forKey: .darkness)
        try c.encode(blurPreset, forKey: .blurPreset)
        try c.encode(speed, forKey: .speed)
        try c.encodeIfPresent(hotkey, forKey: .hotkey)
        try c.encode(dimBrowserChrome, forKey: .dimBrowserChrome)
        try c.encode(browserChromeMode, forKey: .browserChromeMode)
        try c.encode(browserChromeHeight, forKey: .browserChromeHeight)
        try c.encode(browserChromeDarkness, forKey: .browserChromeDarkness)
        try c.encode(browserChromeBlurRadius, forKey: .browserChromeBlurRadius)
        try c.encodeIfPresent(browserChromeHotkey, forKey: .browserChromeHotkey)
        try c.encode(exceptionBundleIDs, forKey: .exceptionBundleIDs)
        try c.encode(browserChromeLight, forKey: .browserChromeLight)
        try c.encode(browserChromeLightDarkness, forKey: .browserChromeLightDarkness)
        try c.encode(browserChromeLightBlurRadius, forKey: .browserChromeLightBlurRadius)
    }
}
