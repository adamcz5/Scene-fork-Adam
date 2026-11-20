import CoreGraphics

/// Merges overlapping rects into their union's bounding box, so the result
/// is a set of rects where no two intersect.
///
/// Spotlight (the dim+blur overlay) cuts a hole for each rect it should
/// leave undimmed. Cutting those holes with an even-odd mask path is only
/// correct when no two holes overlap — two overlapping holes under even-odd
/// double-flip their shared region back to "dimmed", which is wrong whenever
/// the excluded windows legitimately overlap (the overlapping/"freeform"
/// layout feature makes that a real, not just theoretical, case — e.g. two
/// windows of the same app stacked per `CustomLayout.freeformSlots`).
/// Merging first guarantees every hole rect is disjoint, so each one punches
/// a clean hole with no double-flip.
public enum RectMerging {
    /// O(n^2) per merge pass — fine for the handful of windows a single app
    /// (or even a whole screen) has open; not meant for large rect sets.
    public static func mergingOverlapping(_ rects: [CGRect]) -> [CGRect] {
        var result = rects.filter { !$0.isEmpty }
        var mergedSomething = true
        while mergedSomething {
            mergedSomething = false
            outer: for i in result.indices {
                for j in result.indices where j > i {
                    if result[i].intersects(result[j]) {
                        result[i] = result[i].union(result[j])
                        result.remove(at: j)
                        mergedSomething = true
                        break outer
                    }
                }
            }
        }
        return result
    }
}
