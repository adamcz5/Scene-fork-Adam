import CoreGraphics
import os

public enum LayoutEngine {
    /// Maps windows to slots. Windows whose frame already sits on a slot rect
    /// (within `stickyTolerance` points) keep that slot — re-applying a layout
    /// must not reshuffle windows that are already in position. Remaining
    /// windows fill the remaining slots in z-order; leftovers get minimized.
    /// A sticky window's placement targets the slot's exact rect, so
    /// sub-tolerance drift self-heals on re-apply.
    public static func plan(
        windows: [any WindowRef],
        visibleFrame: CGRect,
        layout: Layout,
        stickyTolerance: CGFloat = 10
    ) -> Plan {
        let slotRects = layout.slots.map { $0.absoluteRect(in: visibleFrame) }

        // Sticky pass — z-order priority when two windows sit on the same rect.
        var slotToWindow: [Int: any WindowRef] = [:]
        var stickyIDs = Set<CGWindowID>()
        for window in windows {
            let claimed = slotRects.indices.first { idx in
                slotToWindow[idx] == nil &&
                rectsApproxEqual(window.frame, slotRects[idx], tolerance: stickyTolerance)
            }
            if let idx = claimed {
                slotToWindow[idx] = window
                stickyIDs.insert(window.id)
            }
        }

        // Fill pass — remaining windows (z-order) into remaining slots (index order).
        var overflow: [CGWindowID] = []
        var freeSlots = slotRects.indices.filter { slotToWindow[$0] == nil }[...]
        for window in windows where !stickyIDs.contains(window.id) {
            if let idx = freeSlots.popFirst() {
                slotToWindow[idx] = window
            } else {
                overflow.append(window.id)
            }
        }

        let placements = slotToWindow.keys.sorted().map { idx in
            Placement(
                windowID: slotToWindow[idx]!.id,
                targetFrame: slotRects[idx],
                slotIndex: idx
            )
        }
        return Plan(
            placements: placements,
            toMinimize: overflow,
            leftEmptySlotCount: slotRects.count - slotToWindow.count
        )
    }
}

private let layoutEngineLog = Logger(subsystem: "com.scene.core", category: "layout-engine")

extension LayoutEngine {
    public static func apply(
        _ plan: Plan,
        on windows: [any WindowRef],
        electronTolerancePx: CGFloat = 5
    ) throws -> Outcome {
        if plan.isEmpty { return .noWindows }

        var byID: [CGWindowID: any WindowRef] = [:]
        for w in windows { byID[w.id] = w }

        var placed = 0
        var failed = 0

        for p in plan.placements {
            guard let window = byID[p.windowID] else {
                failed += 1
                continue
            }
            do {
                try applyFrameWithCorrection(p.targetFrame, to: window, tolerance: electronTolerancePx)
                placed += 1
            } catch {
                layoutEngineLog.error("setFrame failed for \(window.bundleID ?? "unknown", privacy: .public): \(String(describing: error), privacy: .public)")
                failed += 1
            }
        }

        var minimized = 0
        for wid in plan.toMinimize {
            guard let window = byID[wid] else { continue }
            do {
                try window.minimize()
                minimized += 1
            } catch {
                layoutEngineLog.error("minimize failed for \(wid): \(String(describing: error), privacy: .public)")
                failed += 1
            }
        }

        return .applied(
            placed: placed,
            minimized: minimized,
            leftEmpty: plan.leftEmptySlotCount,
            failed: failed
        )
    }

    /// Some apps (Electron windows especially, but also natives growing from a
    /// small frame all the way to a full-screen slot) don't honor the whole
    /// requested delta in one AX write — they clamp partway and only accept
    /// the rest once the previous write has landed. A single overshoot
    /// correction was enough for small drifts, but a small→full jump can need
    /// several passes to converge, which is why re-firing "Full" repeatedly
    /// used to be required to actually reach full size. Loop the correction
    /// until the frame lands within tolerance or we give up after a bounded
    /// number of attempts (apps that structurally refuse AX resizing, e.g.
    /// System Settings, never converge — `maxAttempts` caps the cost of that).
    private static func applyFrameWithCorrection(
        _ target: CGRect,
        to window: any WindowRef,
        tolerance: CGFloat,
        maxAttempts: Int = 5
    ) throws {
        try window.setFrame(target)
        var attempt = 1
        while attempt < maxAttempts, !rectsApproxEqual(window.frame, target, tolerance: tolerance) {
            let current = window.frame
            let corrected = CGRect(
                x: target.origin.x + (target.origin.x - current.origin.x),
                y: target.origin.y + (target.origin.y - current.origin.y),
                width: target.width + (target.width - current.width),
                height: target.height + (target.height - current.height)
            )
            try window.setFrame(corrected)
            attempt += 1
        }
    }
}
