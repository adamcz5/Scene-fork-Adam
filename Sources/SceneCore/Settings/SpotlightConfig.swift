import Foundation

/// What stays undimmed while Spotlight is showing.
public enum SpotlightScope: String, Codable, CaseIterable, Sendable {
    /// Only the single focused window is excluded from the dim+blur overlay.
    case activeWindow
    /// Every visible window belonging to the frontmost app is excluded —
    /// useful when working across more than one window of the same app.
    case activeApp
}

/// User-tunable settings for "Spotlight" — a dim+blur overlay that darkens
/// everything except the window (or app) you're currently working in.
///
/// Deliberately not named `FocusMode`: that name is already taken in this
/// codebase by `Workspace.focusMode` / `FocusModeReference`, which invokes a
/// macOS Focus (Do Not Disturb) Shortcut on Workspace activation — a
/// completely different feature. Spotlight has nothing to do with macOS
/// Focus and nothing to do with Workspaces; it's a standalone, always-on
/// (when enabled) overlay driven purely by which window/app is frontmost.
///
/// The dim darkness/blur strength are intentionally NOT configurable here —
/// only whether Spotlight is on, what it excludes, and how long it waits
/// after the last app/window switch before fading in. Strength lives as
/// hardcoded constants on the overlay itself (`SpotlightOverlayWindow` in
/// SceneApp), matching the ask that drove this feature: "let's not worry
/// about that" for the visual intensity, just the behavior.
public struct SpotlightConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var scope: SpotlightScope
    /// Seconds of no app/window switch before the overlay fades in. Clamped
    /// to `[minIdleDelaySeconds, maxIdleDelaySeconds]` by the Settings slider;
    /// stored as-is here so a value from a future wider range still round-trips.
    public var idleDelaySeconds: Double

    public static let minIdleDelaySeconds: Double = 1
    public static let maxIdleDelaySeconds: Double = 8
    public static let defaultIdleDelaySeconds: Double = 2.5

    /// `enabled: false` by default — this changes what's visually on screen
    /// at all times once on, so it should be an explicit opt-in rather than
    /// surprising a user who just upgraded.
    public static let `default` = SpotlightConfig(
        enabled: false,
        scope: .activeWindow,
        idleDelaySeconds: defaultIdleDelaySeconds
    )

    public init(enabled: Bool, scope: SpotlightScope, idleDelaySeconds: Double) {
        self.enabled = enabled
        self.scope = scope
        self.idleDelaySeconds = idleDelaySeconds
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, scope, idleDelaySeconds
    }

    /// All three fields decode with fallbacks so a `SettingsStore` migration
    /// from a pre-Spotlight schema (no `spotlight` key at all) can still
    /// decode a bare `{}` into `.default` if ever needed, and so a
    /// partially-written file (crash mid-write, hand edit) degrades to
    /// defaults field-by-field instead of failing the whole decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.scope = try c.decodeIfPresent(SpotlightScope.self, forKey: .scope) ?? .activeWindow
        self.idleDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .idleDelaySeconds) ?? Self.defaultIdleDelaySeconds
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(scope, forKey: .scope)
        try c.encode(idleDelaySeconds, forKey: .idleDelaySeconds)
    }
}
