import Foundation

/// Pure ring-cycling logic for the filtered ⌥Tab app switcher, split out from
/// `AppSwitcherController` (SceneApp — owns the AppKit/NSRunningApplication/AX
/// side) so the actual cycling math is unit-testable without a running
/// `NSWorkspace`.
public enum AppSwitcherLogic {
    /// Resolves `config.entries` down to the ones actually selectable right
    /// now, ordered for the ring:
    /// - An entry with no `titleContains` matches whenever its app is running.
    /// - An entry WITH `titleContains` additionally needs at least one open
    ///   window of that app whose title contains it (`windowTitles` supplies
    ///   that per bundle ID — backed by AX in `AppSwitcherController`, or a
    ///   `{ _ in [] }` stub when Accessibility isn't granted, which correctly
    ///   drops every title-filtered entry rather than guessing).
    /// - Ordered by `mruOrder` (most-recently-activated entry KEY first — see
    ///   `AppSwitcherEntry.mruKey`, not necessarily just the bundle ID: two
    ///   entries sharing one bundle ID, e.g. "Personal"/"Work" Chrome tiles,
    ///   rank independently as long as the caller can tell them apart —
    ///   `AppSwitcherController.recordActivation` resolves that via the
    ///   frontmost window's title). An entry whose key never shows up in
    ///   `mruOrder` (never resolved apart from its sibling, or simply never
    ///   activated this session) falls back to configured relative order as
    ///   a stable tiebreaker instead of being placed arbitrarily.
    public static func candidates(
        config: AppSwitcherConfig,
        mruOrder: [String],
        runningBundleIDs: Set<String>,
        windowTitles: (String) -> [String] = { _ in [] }
    ) -> [AppSwitcherEntry] {
        guard config.enabled else { return [] }

        func matches(_ entry: AppSwitcherEntry) -> Bool {
            guard runningBundleIDs.contains(entry.bundleID) else { return false }
            guard let filter = entry.titleContains, !filter.isEmpty else { return true }
            return windowTitles(entry.bundleID).contains { $0.localizedCaseInsensitiveContains(filter) }
        }

        var rank: [String: Int] = [:]
        for (i, key) in mruOrder.enumerated() where rank[key] == nil {
            rank[key] = i
        }
        let unseenRank = mruOrder.count

        return config.entries.enumerated()
            .filter { matches($0.element) }
            .sorted { a, b in
                let rankA = rank[a.element.mruKey] ?? unseenRank
                let rankB = rank[b.element.mruKey] ?? unseenRank
                if rankA != rankB { return rankA < rankB }
                return a.offset < b.offset // stable tiebreak: configured order
            }
            .map(\.element)
    }

    /// Index to start the ring at on the first ⌥Tab of a session. If the
    /// frontmost app is in the ring, starts one step past the FIRST entry
    /// matching it — so a single tap immediately jumps to a *different* app,
    /// matching ⌘Tab's "tap once, jump to the last app" feel — otherwise
    /// starts at the front of the ring.
    public static func startIndex(candidates: [AppSwitcherEntry], frontmostBundleID: String?) -> Int {
        guard !candidates.isEmpty else { return 0 }
        guard let frontmostBundleID,
              let idx = candidates.firstIndex(where: { $0.bundleID == frontmostBundleID })
        else { return 0 }
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
