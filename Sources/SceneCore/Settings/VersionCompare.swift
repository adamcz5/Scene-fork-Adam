import Foundation

/// Fail-safe semver-lite comparison used by the passive update nudge.
///
/// Both strings are stripped of a leading `v`, split on `.`, and each
/// component parsed as `Int`. Components that don't parse are dropped
/// via `compactMap`, so malformed inputs can't trigger a spurious
/// "newer" verdict — the function returns `false` (no nudge) in any
/// ambiguous case. A version with fewer components is padded with zeros
/// so `1.2` compares equal to `1.2.0`.
///
/// - Parameters:
///   - tag: Remote release tag, e.g. `"v0.4.3"` or `"0.4.3"`.
///   - bundle: Running bundle version from `CFBundleShortVersionString`,
///     e.g. `"0.4.2"`.
/// - Returns: `true` when `tag` represents a strictly newer version than
///   `bundle`. `false` when equal, older, or either side is unparseable.
public func isVersionTag(_ tag: String, newerThan bundle: String) -> Bool {
    let t = versionComponents(tag)
    let b = versionComponents(bundle)
    guard !t.isEmpty, !b.isEmpty else { return false }
    for i in 0..<max(t.count, b.count) {
        let ti = i < t.count ? t[i] : 0
        let bi = i < b.count ? b[i] : 0
        if ti != bi { return ti > bi }
    }
    return false
}

/// Index of the highest-versioned tag in `tags`, or `nil` if none parse.
///
/// Exists because GitHub's `releases/latest` endpoint does **not** mean
/// "highest version". GitHub defines it as the most recent non-prerelease,
/// non-draft release sorted by `created_at` — and `created_at` is the date of
/// the *commit the tag points at*, not when the release was published. Cut a
/// hotfix from an older commit and `releases/latest` hands back the older
/// release. A user on a much older build would then be offered that one,
/// install it, and be offered the next one on relaunch — updating a version at
/// a time instead of jumping straight to newest.
///
/// Comparing tags ourselves makes "always offer the newest" true by
/// construction rather than by accident of tagging order. Also handles the
/// case pure string sorting gets wrong: `v0.10.0` is newer than `v0.9.0`.
///
/// Unparseable tags (`"nightly"`, `"2026-07-26"`) are skipped rather than
/// guessed at. Ties resolve to the earliest index, which is the newest by
/// `created_at` given GitHub's listing order.
public func indexOfHighestVersion(tags: [String]) -> Int? {
    var best: Int?
    for (i, tag) in tags.enumerated() where !versionComponents(tag).isEmpty {
        guard let b = best else {
            best = i
            continue
        }
        if isVersionTag(tag, newerThan: tags[b]) { best = i }
    }
    return best
}

private func versionComponents(_ s: String) -> [Int] {
    let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
    return trimmed.split(separator: ".").compactMap { Int($0) }
}
