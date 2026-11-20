import AppKit
import ApplicationServices
import CoreGraphics
import SceneCore

/// EXPERIMENTAL: finds a browser window's own top bar — tab strip, address bar,
/// bookmarks bar — so Spotlight can keep dimming that strip while the page
/// itself stays visible.
///
/// Two ways to find it (`SpotlightChromeMode`):
/// - `.automatic` asks the browser, via accessibility, where the PAGE is (its
///   `AXWebArea`); everything above that inside the window is the top bar. That
///   covers tabs + address bar + bookmarks in one go, and follows the bookmarks
///   bar being shown or hidden. If no page area can be found it falls back to
///   the window's `AXToolbar` / `AXTabGroup` elements.
/// - `.fixedHeight` just dims N points down from the top of the window. Needs no
///   accessibility information at all, so it always works — it just doesn't
///   adapt if the toolbars change height.
///
/// Why `prepare(pid:)` exists: Chromium-based browsers don't build their
/// accessibility tree until they believe an assistive app is present, so
/// without nudging them the tree is nearly empty and nothing is found. Setting
/// `AXManualAccessibility` (the flag Electron/Chromium honor for exactly this)
/// switches the tree on. It takes a moment to populate, so it's requested as
/// soon as such a browser becomes frontmost — well before the dim fades in.
///
/// The tree walk is breadth-first and capped (`maxDepth`, `maxVisitedNodes`) and
/// never descends into a page area (a loaded page can be thousands of nodes),
/// and results are cached briefly per window so the main thread isn't walking
/// accessibility on every dim.
@MainActor
enum BrowserChromeDetector {
    static let candidateBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.Browser", // Arc
        "com.vivaldi.Vivaldi",
    ]

    private static let maxDepth = 10
    private static let maxVisitedNodes = 400
    private static let cacheLifetime: TimeInterval = 20
    /// A page area starting this close to the window's top edge means there is
    /// no top bar to dim (e.g. a full-screen or chromeless window).
    private static let minimumBarHeight: CGFloat = 8

    private static var preparedPIDs = Set<pid_t>()
    private static var cache: [CFHashCode: (strip: CGRect?, at: Date)] = [:]

    static func isCandidate(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return candidateBundleIDs.contains(bundleID)
    }

    /// Switches on a browser's accessibility tree (once per process).
    static func prepare(pid: pid_t) {
        guard !preparedPIDs.contains(pid) else { return }
        preparedPIDs.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// The strip to re-darken inside `windowElement`, in NS screen coordinates,
    /// or `nil` when this isn't a recognized browser or nothing was found.
    static func chromeRegions(
        windowElement: AXUIElement,
        bundleID: String?,
        mode: SpotlightChromeMode,
        fixedHeight: Double
    ) -> [CGRect]? {
        guard isCandidate(bundleID: bundleID),
              let windowFrame = AXWindowLookup.axFrame(of: windowElement)
        else { return nil }

        let strip: CGRect?
        switch mode {
        case .fixedHeight:
            strip = topStrip(of: windowFrame, height: CGFloat(fixedHeight))
        case .automatic:
            strip = cachedAutomaticStrip(windowElement: windowElement, windowFrame: windowFrame)
        }
        guard let strip, strip.height >= minimumBarHeight else { return nil }
        return [DisplayCoordinates.axToNS(strip)]
    }

    // MARK: - Diagnostics (Settings → "Test on open browser")

    struct Detection {
        let appName: String
        /// Height in points of the top bar the automatic mode would dim, or
        /// `nil` if it couldn't find one.
        let topBarHeight: CGFloat?
    }

    /// Runs the automatic detection on every running recognized browser's
    /// front window, ignoring the cache.
    static func detectRunningBrowsers() -> [Detection] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, isCandidate(bundleID: app.bundleIdentifier) else { return nil }
            prepare(pid: app.processIdentifier)
            let element = AXUIElementCreateApplication(app.processIdentifier)
            guard let window = frontWindow(of: element),
                  let windowFrame = AXWindowLookup.axFrame(of: window)
            else { return nil }
            let height = automaticStrip(windowElement: window, windowFrame: windowFrame)?.height
            return Detection(appName: app.localizedName ?? app.bundleIdentifier ?? "Browser", topBarHeight: height)
        }
    }

    private static func frontWindow(of app: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let value = axAttribute(app, attribute as String), CFGetTypeID(value) == AXUIElementGetTypeID() {
                return (value as! AXUIElement)
            }
        }
        return (axAttribute(app, kAXWindowsAttribute as String) as? [AXUIElement])?.first
    }

    // MARK: - Strip computation

    /// `windowFrame` and the result are in AX coordinates (top-left origin).
    private static func topStrip(of windowFrame: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: windowFrame.minX, y: windowFrame.minY,
               width: windowFrame.width, height: min(max(height, 0), windowFrame.height))
    }

    private static func cachedAutomaticStrip(windowElement: AXUIElement, windowFrame: CGRect) -> CGRect? {
        let key = CFHash(windowElement)
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < cacheLifetime,
           let strip = hit.strip {
            // Reuse the measured height but follow the window if it moved/resized.
            return topStrip(of: windowFrame, height: strip.height)
        }
        let strip = automaticStrip(windowElement: windowElement, windowFrame: windowFrame)
        // Only cache successes: a miss is often just the accessibility tree
        // not having filled in yet, and should be retried next time.
        if let strip { cache[key] = (strip, Date()) }
        return strip
    }

    private static func automaticStrip(windowElement: AXUIElement, windowFrame: CGRect) -> CGRect? {
        var pageArea: CGRect?
        var barElements: [CGRect] = []
        var visited = 0
        var queue: [(element: AXUIElement, depth: Int)] = [(windowElement, 0)]
        var cursor = 0

        while cursor < queue.count, visited < maxVisitedNodes {
            let (element, depth) = queue[cursor]
            cursor += 1
            visited += 1

            let role = axAttribute(element, kAXRoleAttribute as String) as? String
            if role == "AXWebArea" {
                // Never descend into the page; keep the biggest one (dev tools
                // and other embedded views also show up as web areas).
                if let frame = AXWindowLookup.axFrame(of: element),
                   frame.width * frame.height > (pageArea.map { $0.width * $0.height } ?? 0) {
                    pageArea = frame
                }
                continue
            }
            if role == "AXToolbar" || role == "AXTabGroup" {
                if let frame = AXWindowLookup.axFrame(of: element) { barElements.append(frame) }
                continue
            }
            guard depth < maxDepth,
                  let children = axAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement]
            else { continue }
            for child in children { queue.append((child, depth + 1)) }
        }

        if let pageArea, pageArea.minY - windowFrame.minY >= minimumBarHeight {
            return topStrip(of: windowFrame, height: pageArea.minY - windowFrame.minY)
        }
        if let first = barElements.first {
            let union = barElements.dropFirst().reduce(first) { $0.union($1) }
            let bottom = min(union.maxY, windowFrame.maxY)
            if bottom - windowFrame.minY >= minimumBarHeight {
                return topStrip(of: windowFrame, height: bottom - windowFrame.minY)
            }
        }
        return nil
    }

    private static func axAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
