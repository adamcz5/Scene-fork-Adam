import ApplicationServices
import CoreGraphics

/// EXPERIMENTAL, heuristic-only: looks inside a browser window's AX tree for
/// its own chrome — tab strip, address bar/toolbar, bookmark bar — so
/// Spotlight can re-darken just that strip while leaving the page content
/// undimmed, instead of treating the whole browser window as one undimmed
/// block.
///
/// This is NOT a stable API contract: Chromium-based browsers expose their
/// tab strip and toolbars as top-level `AXTabGroup` / `AXToolbar` children of
/// the window, which is what this walks for — but that internal AX structure
/// has changed across Chrome versions before and isn't guaranteed to hold for
/// every Chromium build, and hasn't been verified at all against Safari or
/// Firefox's AX trees (neither is in `candidateBundleIDs`, so this never even
/// tries for them). When nothing matches, `chromeRegions` returns `nil` and
/// the caller falls back to leaving the whole window undimmed — the
/// pre-existing behavior — rather than guessing wrong.
///
/// Deliberately bounded (`maxDepth`, `maxVisitedNodes`) and NEVER descends
/// into `AXWebArea` — that's the loaded page's own DOM accessibility tree,
/// which can be thousands of nodes deep, and is also the one region that must
/// stay undimmed, so there's nothing to gain by walking into it.
enum BrowserChromeDetector {
    private static let candidateBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser", // Arc
        "com.vivaldi.Vivaldi",
    ]

    private static let maxDepth = 4
    private static let maxVisitedNodes = 300

    /// Returns chrome-strip rects (NS screen coordinates, same convention as
    /// `AXWindowLookup.axFrame` callers elsewhere) to re-darken inside an
    /// otherwise-undimmed browser window, or `nil` if this isn't a
    /// recognized browser or nothing was found.
    static func chromeRegions(windowElement: AXUIElement, bundleID: String?) -> [CGRect]? {
        guard let bundleID, candidateBundleIDs.contains(bundleID) else { return nil }
        var rects: [CGRect] = []
        var visited = 0
        collect(windowElement, depth: 0, visited: &visited, into: &rects)
        return rects.isEmpty ? nil : rects
    }

    private static func collect(_ element: AXUIElement, depth: Int, visited: inout Int, into rects: inout [CGRect]) {
        visited += 1
        guard visited <= maxVisitedNodes, depth <= maxDepth else { return }

        let role = axAttribute(element, kAXRoleAttribute as String) as? String

        // Never descend into the page's own content — huge tree, and it's
        // exactly the region that must stay undimmed.
        if role == "AXWebArea" { return }

        if role == "AXToolbar" || role == "AXTabGroup" {
            if let axFrame = AXWindowLookup.axFrame(of: element) {
                rects.append(DisplayCoordinates.axToNS(axFrame))
            }
            // A matched toolbar/tab-group's own children are its buttons/tabs
            // — nothing further to find by descending into them.
            return
        }

        guard let children = axAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement] else { return }
        for child in children {
            collect(child, depth: depth + 1, visited: &visited, into: &rects)
        }
    }

    private static func axAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
