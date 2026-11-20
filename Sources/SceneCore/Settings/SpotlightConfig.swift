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

    public static let minIdleDelaySeconds: Double = 1
    public static let maxIdleDelaySeconds: Double = 8
    public static let defaultIdleDelaySeconds: Double = 2.5

    public static let minDarkness: Double = 0.2
    public static let maxDarkness: Double = 0.9
    public static let defaultDarkness: Double = 0.45

    public static let minSpeed: Double = 0.5
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
        dimBrowserChrome: Bool = false
    ) {
        self.enabled = enabled
        self.exclusionMode = exclusionMode
        self.idleDelaySeconds = idleDelaySeconds
        self.darkness = darkness
        self.blurPreset = blurPreset
        self.speed = speed
        self.hotkey = hotkey
        self.dimBrowserChrome = dimBrowserChrome
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, exclusionMode, idleDelaySeconds, darkness, blurPreset, speed, hotkey, dimBrowserChrome
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
    }
}
