import CoreGraphics
import Foundation

/// User-tunable settings for the V0.3 drag-to-swap feature.
/// Persisted alongside `AnimationConfig` in `SettingsStore`.
public struct DragSwapConfig: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let distanceThresholdPt: CGFloat
    /// `nil` (the V0.3–V0.8 behavior): once `enabled`, stickiness stays active
    /// indefinitely. A value: stickiness only applies for that many seconds
    /// after each layout/workspace apply, then auto-turns-off until the next
    /// apply re-arms it — lets a user drag freely again without visiting
    /// Settings every time. See `Coordinator.stickyWindowStartedAt`.
    public let autoDisableAfterSeconds: TimeInterval?

    public static let minThresholdPt: CGFloat = 10
    public static let maxThresholdPt: CGFloat = 100
    public static let minAutoDisableSeconds: TimeInterval = 2
    public static let maxAutoDisableSeconds: TimeInterval = 60
    public static let defaultAutoDisableSeconds: TimeInterval = 5

    public init(enabled: Bool, distanceThresholdPt: CGFloat, autoDisableAfterSeconds: TimeInterval? = nil) {
        self.enabled = enabled
        self.distanceThresholdPt = min(max(distanceThresholdPt, Self.minThresholdPt), Self.maxThresholdPt)
        self.autoDisableAfterSeconds = autoDisableAfterSeconds.map {
            min(max($0, Self.minAutoDisableSeconds), Self.maxAutoDisableSeconds)
        }
    }

    public static let `default` = DragSwapConfig(enabled: true, distanceThresholdPt: 30)

    /// Returns a copy with `enabled` overridden — used by `Coordinator` to hand
    /// `DragSwapController`/`SeamResizeController` the *effective* enabled
    /// state (config `enabled` AND, in timed mode, still inside the sticky
    /// window) without disturbing the persisted config itself.
    public func withEnabled(_ enabled: Bool) -> DragSwapConfig {
        DragSwapConfig(enabled: enabled, distanceThresholdPt: distanceThresholdPt, autoDisableAfterSeconds: autoDisableAfterSeconds)
    }

    private enum CodingKeys: String, CodingKey { case enabled, distanceThresholdPt, autoDisableAfterSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(CGFloat.self, forKey: .distanceThresholdPt)
        self.init(
            enabled: try c.decode(Bool.self, forKey: .enabled),
            distanceThresholdPt: raw,
            autoDisableAfterSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .autoDisableAfterSeconds)
        )
    }
}
