import Foundation

/// UI-facing tri-state view of `DragSwapConfig`'s `enabled` / `autoDisableAfterSeconds`
/// fields, shared between Settings' `InteractionTab` and the menu bar's sticky
/// toggle so both present the exact same three choices and stay in sync.
public enum StickyModeOption: Hashable, Sendable {
    case off, always, timed
}

extension DragSwapConfig {
    public var stickyModeOption: StickyModeOption {
        guard enabled else { return .off }
        return autoDisableAfterSeconds == nil ? .always : .timed
    }

    /// Persists `option` via `store.setDragSwap`, preserving `distanceThresholdPt`.
    /// Switching to `.off` keeps whatever `autoDisableAfterSeconds` was set so
    /// switching back to `.timed` later restores the same duration instead of
    /// resetting to the default.
    public func applying(_ option: StickyModeOption, to store: SettingsStore) {
        let next: DragSwapConfig
        switch option {
        case .off:
            next = DragSwapConfig(
                enabled: false,
                distanceThresholdPt: distanceThresholdPt,
                autoDisableAfterSeconds: autoDisableAfterSeconds
            )
        case .always:
            next = DragSwapConfig(
                enabled: true,
                distanceThresholdPt: distanceThresholdPt,
                autoDisableAfterSeconds: nil
            )
        case .timed:
            next = DragSwapConfig(
                enabled: true,
                distanceThresholdPt: distanceThresholdPt,
                autoDisableAfterSeconds: autoDisableAfterSeconds ?? Self.defaultAutoDisableSeconds
            )
        }
        try? store.setDragSwap(next)
    }
}
