import SwiftUI
import SceneCore

/// V0.10 "overlapping layout build" canvas editor — the visual counterpart to
/// `CustomLayout.freeformSlots`. Unlike `CustomLayoutCanvasEditor`'s split
/// tree (every slot tiles, never overlaps), each slot here is an independent
/// rect: all four edges drag separately and slots are allowed to sit on top
/// of one another — e.g. a Slack strip down the left edge with Chrome laid
/// on top of it, leaving a visible sliver of Slack showing.
///
/// This is the third editor path in `LayoutDraftEditor`: when a draft's
/// `freeformSlots` is non-empty we render this instead of
/// `CustomLayoutCanvasEditor` or the template-based `LayoutEditorView`.
///
/// Design notes:
/// - Array order IS the initial z-order (`FreeformSlot`'s doc comment) — drag
///   handles never need to hit-test "which window is under this click": once
///   the layout is applied, that's just normal macOS window click-to-front
///   behavior. "Bring to Front" / "Send to Back" here only decide which
///   window lands on top the moment the layout is *applied*.
/// - No minimum slot size is enforced beyond `FreeformSlot.minimumDimension`
///   (a guard against a degenerate zero-size drag, not a design floor) —
///   mirrors the V0.7 split-tree editor's same choice.
/// - Resize handles and the per-slot toolbar only render for the selected
///   slot — with slots free to overlap, showing every handle for every slot
///   at once would make dense layouts unusable to grab precisely.
struct FreeformLayoutCanvasEditor: View {
    @Binding var draft: CustomLayout
    let canSave: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("layouts.editor.name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text(String(format: String(localized: "layouts.freeform.slot_count"), slots.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addSlot()
                } label: {
                    Label("layouts.freeform.add_slot", systemImage: "plus.square.on.square")
                }
            }

            Text("layouts.freeform.canvas_hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            canvas

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("settings.action.cancel", action: onCancel)
                Button("settings.action.save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding()
    }

    private var slots: [FreeformSlot] {
        draft.freeformSlots ?? []
    }

    private var canvas: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.05))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = nil }

                ForEach(slots) { slot in
                    FreeformSlotView(
                        slot: binding(for: slot.id),
                        containerSize: geo.size,
                        isSelected: selectedID == slot.id,
                        canDelete: slots.count > 1,
                        onSelect: { selectedID = slot.id },
                        onBringToFront: { bringToFront(slot.id) },
                        onSendToBack: { sendToBack(slot.id) },
                        onDelete: { delete(slot.id) }
                    )
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(minHeight: 260)
    }

    private func binding(for id: UUID) -> Binding<FreeformSlot> {
        Binding(
            get: { slots.first(where: { $0.id == id }) ?? FreeformSlot(id: id, rect: .zero) },
            set: { newValue in
                guard var arr = draft.freeformSlots,
                      let idx = arr.firstIndex(where: { $0.id == id }) else { return }
                arr[idx] = newValue.clamped()
                draft.freeformSlots = arr
            }
        )
    }

    /// New slots cascade diagonally so repeated adds land somewhere visible
    /// rather than stacking exactly on top of the previous one.
    private func addSlot() {
        var arr = draft.freeformSlots ?? []
        let step = CGFloat(arr.count % 5) * 0.05
        let rect = CGRect(x: 0.25 + step, y: 0.25 + step, width: 0.4, height: 0.4)
        let new = FreeformSlot(rect: rect).clamped()
        arr.append(new)
        draft.freeformSlots = arr
        selectedID = new.id
    }

    private func bringToFront(_ id: UUID) {
        guard var arr = draft.freeformSlots, let idx = arr.firstIndex(where: { $0.id == id }) else { return }
        let item = arr.remove(at: idx)
        arr.append(item)
        draft.freeformSlots = arr
    }

    private func sendToBack(_ id: UUID) {
        guard var arr = draft.freeformSlots, let idx = arr.firstIndex(where: { $0.id == id }) else { return }
        let item = arr.remove(at: idx)
        arr.insert(item, at: 0)
        draft.freeformSlots = arr
    }

    private func delete(_ id: UUID) {
        guard var arr = draft.freeformSlots else { return }
        arr.removeAll { $0.id == id }
        draft.freeformSlots = arr
        if selectedID == id { selectedID = nil }
    }
}

// MARK: - One slot

private enum SlotEdge {
    case top, bottom, left, right
}

private struct FreeformSlotView: View {
    @Binding var slot: FreeformSlot
    let containerSize: CGSize
    let isSelected: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onBringToFront: () -> Void
    let onSendToBack: () -> Void
    let onDelete: () -> Void

    /// Captured at the start of any drag (move or edge-resize) so each
    /// `onChanged` frame computes the new rect from the ORIGINAL rect plus
    /// the gesture's cumulative translation, rather than compounding deltas
    /// frame-over-frame — same pattern as `CustomLayoutCanvasEditor`'s
    /// `SeamHandleView.dragStartRatio`.
    @State private var dragStartRect: CGRect?

    private var absRect: CGRect {
        CGRect(
            x: slot.rect.minX * containerSize.width,
            y: slot.rect.minY * containerSize.height,
            width: slot.rect.width * containerSize.width,
            height: slot.rect.height * containerSize.height
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(isSelected ? 0.3 : 0.16))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 1))
                .contentShape(Rectangle())
                .gesture(moveGesture)

            if isSelected {
                edgeHandle(.top)
                edgeHandle(.bottom)
                edgeHandle(.left)
                edgeHandle(.right)
                toolbar
            }
        }
        .frame(width: max(1, absRect.width), height: max(1, absRect.height))
        .offset(x: absRect.minX, y: absRect.minY)
    }

    private var moveGesture: some Gesture {
        // `minimumDistance: 0` so a plain click (no movement at all) still
        // fires `onChanged` once and selects the slot — a `minimumDistance`
        // above zero would require the mouse to actually travel before a
        // tap-only click registers as anything.
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                onSelect()
                if dragStartRect == nil { dragStartRect = slot.rect }
                guard let start = dragStartRect, containerSize.width > 0, containerSize.height > 0 else { return }
                let dx = value.translation.width / containerSize.width
                let dy = value.translation.height / containerSize.height
                slot.rect = clampedMove(
                    CGRect(x: start.minX + dx, y: start.minY + dy, width: start.width, height: start.height)
                )
            }
            .onEnded { _ in dragStartRect = nil }
    }

    /// Moving (as opposed to resizing an edge) must not change the slot's
    /// size when it reaches the canvas boundary — it should stop, not
    /// squash. `FreeformSlot.clamped()` would shrink the far edge instead,
    /// which is correct for edge-resize but wrong for a plain drag.
    private func clampedMove(_ rect: CGRect) -> CGRect {
        let w = min(max(rect.width, FreeformSlot.minimumDimension), 1)
        let h = min(max(rect.height, FreeformSlot.minimumDimension), 1)
        let x = min(max(rect.minX, 0), 1 - w)
        let y = min(max(rect.minY, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    @ViewBuilder
    private func edgeHandle(_ edge: SlotEdge) -> some View {
        // Bar runs the full length of the slot's own edge; thickness is fixed
        // (10pt hit area, 2pt visible stripe) regardless of orientation.
        let isHorizontalEdge = edge == .top || edge == .bottom
        let w = max(1, absRect.width)
        let h = max(1, absRect.height)
        Rectangle()
            .fill(Color.clear)
            .frame(width: isHorizontalEdge ? w : 10, height: isHorizontalEdge ? 10 : h)
            .overlay(
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: isHorizontalEdge ? w : 2, height: isHorizontalEdge ? 2 : h)
            )
            .contentShape(Rectangle())
            .position(handlePosition(edge))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        onSelect()
                        if dragStartRect == nil { dragStartRect = slot.rect }
                        guard let start = dragStartRect, containerSize.width > 0, containerSize.height > 0 else { return }
                        let dx = value.translation.width / containerSize.width
                        let dy = value.translation.height / containerSize.height
                        slot.rect = resized(start, edge: edge, dx: dx, dy: dy)
                    }
                    .onEnded { _ in dragStartRect = nil }
            )
            .onHover { inside in
                if inside {
                    switch edge {
                    case .top, .bottom: NSCursor.resizeUpDown.push()
                    case .left, .right: NSCursor.resizeLeftRight.push()
                    }
                } else {
                    NSCursor.pop()
                }
            }
    }

    private func handlePosition(_ edge: SlotEdge) -> CGPoint {
        let w = max(1, absRect.width)
        let h = max(1, absRect.height)
        switch edge {
        case .top:    return CGPoint(x: w / 2, y: 0)
        case .bottom: return CGPoint(x: w / 2, y: h)
        case .left:   return CGPoint(x: 0, y: h / 2)
        case .right:  return CGPoint(x: w, y: h / 2)
        }
    }

    /// Computes the new unit rect for one edge moving, holding the OPPOSITE
    /// edge fixed. `CGRect.minX`/`.maxX`/`.minY`/`.maxY` standardize even for
    /// a negative-width/height rect, so dragging an edge past its opposite
    /// one is safe here — `FreeformSlot.clamped()` (applied by the parent's
    /// binding setter) resolves the final min/max and enforces the minimum
    /// dimension.
    private func resized(_ start: CGRect, edge: SlotEdge, dx: CGFloat, dy: CGFloat) -> CGRect {
        switch edge {
        case .top:
            let newMinY = start.minY + dy
            return CGRect(x: start.minX, y: newMinY, width: start.width, height: start.maxY - newMinY)
        case .bottom:
            let newMaxY = start.maxY + dy
            return CGRect(x: start.minX, y: start.minY, width: start.width, height: newMaxY - start.minY)
        case .left:
            let newMinX = start.minX + dx
            return CGRect(x: newMinX, y: start.minY, width: start.maxX - newMinX, height: start.height)
        case .right:
            let newMaxX = start.maxX + dx
            return CGRect(x: start.minX, y: start.minY, width: newMaxX - start.minX, height: start.height)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            toolbarButton(systemImage: "square.stack.3d.up", help: "layouts.freeform.bring_to_front", action: onBringToFront)
            toolbarButton(systemImage: "square.stack.3d.down", help: "layouts.freeform.send_to_back", action: onSendToBack)
            if canDelete {
                toolbarButton(systemImage: "trash", help: "layouts.custom.delete_slot", action: onDelete)
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        // Inset from the slot's own top-trailing corner (not floated above
        // it) so it never gets clipped by the canvas's rounded-rect mask.
        .position(x: max(1, absRect.width) - 36, y: 16)
    }

    private func toolbarButton(systemImage: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
