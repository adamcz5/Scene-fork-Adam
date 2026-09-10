import Foundation

/// Pure ring-cycling logic for the filtered ⌥Tab app switcher, split out from
/// `AppSwitcherController` (SceneApp — owns the AppKit/NSRunningApplication
/// side) so the actual cycling math is unit-testable without a running
/// `NSWorkspace`.
public enum AppSwitcherLogic {
    /// Filters `runningBundleIDs` down to `config.bundleIDs`, preserving the
    /// config's order (not whatever order `NSWorkspace.runningApplications`
    /// happens to enumerate in) — the ring is a stable, user-controlled list,
    /// not a most-recently-used one.
    public static func candidates(config: AppSwitcherConfig, runningBundleIDs: Set<String>) -> [String] {
        guard config.enabled else { return [] }
        return config.bundleIDs.filter { runningBundleIDs.contains($0) }
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
