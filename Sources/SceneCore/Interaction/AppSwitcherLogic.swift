import Foundation

/// Pure ring-cycling logic for the filtered ⌥Tab app switcher, split out from
/// `AppSwitcherController` (SceneApp — owns the AppKit/NSRunningApplication
/// side) so the actual cycling math is unit-testable without a running
/// `NSWorkspace`.
public enum AppSwitcherLogic {
    /// Filters `runningBundleIDs` down to `config.bundleIDs` (the allow-list —
    /// order here doesn't matter, it's just set membership), then orders the
    /// result by `mruOrder` (most-recently-activated first) so the ring reads
    /// left-to-right from most to least recently used, matching ⌘Tab's own
    /// convention. `mruOrder` won't yet mention an app that's running but was
    /// never activated this session (e.g. launched in the background before
    /// Scene started tracking) — any such app is appended at the end, in
    /// `config.bundleIDs`' order, rather than silently dropped.
    public static func candidates(config: AppSwitcherConfig, mruOrder: [String], runningBundleIDs: Set<String>) -> [String] {
        guard config.enabled else { return [] }
        let allowed = Set(config.bundleIDs)
        var seen = Set<String>()
        var result: [String] = []
        for bundleID in mruOrder where allowed.contains(bundleID) && runningBundleIDs.contains(bundleID) {
            if seen.insert(bundleID).inserted {
                result.append(bundleID)
            }
        }
        for bundleID in config.bundleIDs where runningBundleIDs.contains(bundleID) && !seen.contains(bundleID) {
            seen.insert(bundleID)
            result.append(bundleID)
        }
        return result
    }

    /// Index to start the ring at on the first ⌥Tab of a session. If the
    /// frontmost app is in the ring, starts one step past it — so a single
    /// tap immediately jumps to a *different* app, matching ⌘Tab's "tap once,
    /// jump to the last app" feel — otherwise starts at the front of the ring.
    public static func startIndex(candidates: [String], frontmostBundleID: String?) -> Int {
        guard !candidates.isEmpty else { return 0 }
        guard let frontmostBundleID, let idx = candidates.firstIndex(of: frontmostBundleID) else {
            return 0
        }
        return (idx + 1) % candidates.count
    }

    /// Advances `index` by one step within a ring of `count` entries, wrapping
    /// in either direction. Returns 0 for an empty ring (caller should not act
    /// on it, but this keeps the function total rather than partial).
    public static func advance(index: Int, count: Int, reverse: Bool) -> Int {
        guard count > 0 else { return 0 }
        let normalized = ((index % count) + count) % count
        return reverse ? (normalized - 1 + count) % count : (normalized + 1) % count
    }
}
