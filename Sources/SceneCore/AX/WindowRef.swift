import CoreGraphics

public protocol WindowRef: AnyObject {
    var id: CGWindowID { get }
    var bundleID: String? { get }
    /// Window title, e.g. "Gmail - user@work.com - Google Chrome". Used to
    /// disambiguate multiple windows of the same bundle ID (different browser
    /// profiles/accounts) when a `WorkspaceSlotAssignment.titleContains` hint
    /// is set. `nil` when unavailable (e.g. app doesn't expose `AXTitle`).
    var title: String? { get }
    var frame: CGRect { get }
    var isMinimized: Bool { get }
    var isFullscreen: Bool { get }
    func setFrame(_ rect: CGRect) throws
    func minimize() throws
    /// Raises this window to the front of its own z-order — a pure ordering
    /// change, no activation/focus-stealing of other apps and nothing hidden
    /// or minimized. Used after applying a layout so the just-placed windows
    /// are visible above whatever was already on top, while every other
    /// window stays exactly as-is (still enumerable via Mission Control /
    /// "all windows" Exposé — raising never removes a window from that list).
    func raise() throws
}
