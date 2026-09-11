import AppKit
import ApplicationServices
import CoreGraphics

public enum AXWindowEnumerator {
    public enum EnumerationError: Error {
        case permissionDenied
        case cgWindowListFailed
    }

    public static func listVisibleWindows(on screen: NSScreen) throws -> [AXWindow] {
        guard AXPermission.check() else { throw EnumerationError.permissionDenied }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw EnumerationError.cgWindowListFailed
        }

        var results: [AXWindow] = []
        for info in list {
            guard
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                let cgBounds = boundsFromDict(boundsDict)
            else { continue }

            // Ownership test uses `frame`, not `visibleFrame`: a window whose
            // center happens to sit in the Dock strip still belongs to this
            // display, and `visibleFrame` would drop it from the plan entirely
            // — and drop it only while the Dock happened to be on this screen,
            // since the Dock follows the pointer. See `TilingFrame`.
            let centerTopLeft = CGPoint(x: cgBounds.midX, y: cgBounds.midY)
            guard screen.frame.contains(DisplayCoordinates.axToNS(centerTopLeft)) else { continue }

            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            guard let axWindow = buildAXWindow(pid: pid, id: id, bundleID: bundleID, bounds: cgBounds),
                  !axWindow.isMinimized, !axWindow.isFullscreen
            else { continue }

            // Same dedup as `listVisibleWindows(forBundleID:)` below, and for
            // the same reason: Chrome (and other multi-process/Electron-style
            // apps) can emit two raw CGWindowList entries — the real window
            // plus an internal compositor/helper surface — sharing identical
            // bounds, which `buildAXWindow`'s bounds-matching then resolves
            // to the SAME underlying `AXUIElement` twice. Left undeduped,
            // `LayoutEngine.plan` would see a phantom "extra" window and
            // place it into a slot that should've gone to (or displaced) a
            // real one — windows landing in the wrong zone, or a real window
            // getting bumped to overflow/minimized, for no reason visible to
            // the user. This was very likely the cause of layouts appearing
            // to shuffle windows around "randomly" when several windows of
            // the same app (e.g. two Chrome profiles) were open.
            let alreadySeen = results.contains { CFEqual($0.axElement, axWindow.axElement) }
            if !alreadySeen {
                results.append(axWindow)
            }
        }
        return results
    }

    /// V0.9: windows belonging to one specific app, for the app switcher's
    /// per-window drill-down (HopTab-style — see `AppSwitcherController`).
    /// Unlike `listVisibleWindows(on:)`, not scoped to a particular
    /// `NSScreen` — the switcher isn't "which display is the mouse over",
    /// it's "which windows does this app have". `.optionOnScreenOnly` still
    /// restricts to the current Space, matching HopTab's own
    /// space-aware window picker.
    public static func listVisibleWindows(forBundleID bundleID: String) throws -> [AXWindow] {
        guard AXPermission.check() else { throw EnumerationError.permissionDenied }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw EnumerationError.cgWindowListFailed
        }

        var results: [AXWindow] = []
        for info in list {
            guard
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                let cgBounds = boundsFromDict(boundsDict),
                NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID
            else { continue }

            guard let axWindow = buildAXWindow(pid: pid, id: id, bundleID: bundleID, bounds: cgBounds),
                  !axWindow.isMinimized, !axWindow.isFullscreen
            else { continue }

            // Chrome (and other multi-process/Electron-style apps) can emit
            // TWO separate entries in the raw window list — the real window
            // plus an internal compositor/helper surface — that share the
            // exact same bounds. `buildAXWindow` matches purely by bounds, so
            // both CGWindowList entries resolve back to the SAME underlying
            // `AXUIElement`, and without this check the same physical window
            // would show up twice in the drill-down list. `CFEqual` (not `==`
            // — `AXUIElement` doesn't bridge to Swift's `Equatable`) compares
            // by actual AX element identity, not just coincidentally-equal bounds.
            let alreadySeen = results.contains { CFEqual($0.axElement, axWindow.axElement) }
            if !alreadySeen {
                results.append(axWindow)
            }
        }
        return results
    }

    // MARK: - private

    private static func boundsFromDict(_ dict: [String: CGFloat]) -> CGRect? {
        guard
            let x = dict["X"], let y = dict["Y"],
            let w = dict["Width"], let h = dict["Height"]
        else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func buildAXWindow(pid: pid_t, id: CGWindowID, bundleID: String?, bounds: CGRect) -> AXWindow? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement]
        else { return nil }

        // Exact match first: `_AXUIElementGetWindow` is a private-but-widely-used
        // API (Rectangle, yabai, Contexts all rely on it) that maps an
        // AXUIElement straight to its real CGWindowID, no geometry guessing
        // involved. This is what lets two windows with IDENTICAL bounds (e.g.
        // two Chrome windows both simply maximized on the same screen) resolve
        // to two DIFFERENT AXUIElements instead of collapsing onto whichever
        // one happens to come first in `kAXWindowsAttribute`. Bounds-matching
        // below remains as a fallback for the rare case this private call
        // fails (sandboxed/unusual apps) — see the phantom-duplicate comments
        // on the call sites for why that fallback still needs its own dedup.
        for window in windows {
            var resolvedID: CGWindowID = 0
            if _AXUIElementGetWindow(window, &resolvedID) == .success, resolvedID == id {
                return AXWindow(element: window, id: id, pid: pid, bundleID: bundleID)
            }
        }

        for window in windows {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
            guard let pos = posRef, let size = sizeRef else { continue }

            var point = CGPoint.zero
            var sz = CGSize.zero
            AXValueGetValue(pos as! AXValue, .cgPoint, &point)
            AXValueGetValue(size as! AXValue, .cgSize, &sz)
            let axFrame = CGRect(origin: point, size: sz)

            if rectsApproxEqual(axFrame, bounds, tolerance: 2) {
                return AXWindow(element: window, id: id, pid: pid, bundleID: bundleID)
            }
        }
        return nil
    }
}

/// Private API used by Rectangle, yabai, and Contexts to correlate an
/// `AXUIElement` window handle with its real `CGWindowID` exactly, instead of
/// guessing from bounds. Not in any public header, so it's declared here via
/// `@_silgen_name` against the symbol actually exported by ApplicationServices.
@_silgen_name("_AXUIElementGetWindow")
@discardableResult
private func _AXUIElementGetWindow(_ element: AXUIElement, _ outID: inout CGWindowID) -> AXError
