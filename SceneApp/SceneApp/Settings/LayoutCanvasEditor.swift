import AppKit
import SwiftUI
import SceneCore

/// The one layout editor. Replaces the three earlier, separately-entered
/// editors (template sliders, split-tree canvas, overlapping canvas): every
/// layout — whatever way it was originally authored — is edited here as a flat
/// list of independent rectangles, because that representation can express
/// all of them (a template or split tree is just a set of non-overlapping
/// rects; an overlapping layout is a set that may overlap).
///
/// Editing model:
/// - Geometry is read through `slots`: the draft's `freeformSlots` if it has
///   any, otherwise the flattened template/tree (`CustomLayout.toLayout()`,
///   with deterministic ids so selection survives re-renders). Nothing is
///   written until the user actually edits geometry — merely opening a layout
///   never marks it modified.
/// - The first geometry edit converts the draft: `freeformSlots` takes over
///   (it already wins in `CustomLayout.toLayout()`'s precedence) and the old
///   `customTree` is cleared. Layouts saved before this editor existed still
///   load exactly as before.
/// - "Start from a preset" re-seeds the slots from a `LayoutTemplate`, which
///   keeps the quick symmetric layouts (2 columns, 2×2, L-shapes…) without a
///   separate editor.
///
/// Interaction fixes versus the old overlapping editor:
/// - Drags measure translation in the canvas' own (fixed) coordinate space.
///   The old gestures used each slot's *local* space, which moves with the
///   slot as it's dragged — so the measured translation shrank as the slot
///   caught up with the pointer, and the slot lagged behind the cursor.
/// - Resize handles live in a layer above every slot body, so a slot that
///   overlaps the selected one can never swallow a click meant for its handle.
/// - Click-to-select (tap) and drag-to-move (drag past a few points) are
///   separate gestures, so a plain click never nudges a slot.
/// - The selected slot has an unmistakable ring + corner/edge handles, every
///   slot carries a number badge, and a chip row below the canvas selects any
///   slot directly — useful when slots overlap completely.
struct LayoutCanvasEditor: View {
    @Binding var draft: CustomLayout
    let canSave: Bool
    let onSave: () -> Void
    let onCancel: () -> Void

    @EnvironmentObject private var layoutVM: LayoutStoreViewModel
    @EnvironmentObject private var workspaceVM: WorkspaceStoreViewModel
    @EnvironmentObject private var settingsVM: SettingsStoreViewModel

    @State private var selectedID: UUID?
    @State private var previewScreenIndex: Int = 0
    @State private var snapToEdges: Bool = true
    /// The slot's rect at the moment the current drag began, so every
    /// `onChanged` frame derives the new rect from the ORIGINAL plus the
    /// gesture's cumulative translation instead of compounding deltas.
    @State private var dragOrigin: DragOrigin?

    private struct DragOrigin {
        let id: UUID
        let rect: CGRect
    }

    private static let canvasSpace = "layoutCanvas"
    /// Visible handle thickness / grab size in points.
    private static let grab: CGFloat = 16
    /// Distance (points) within which an edge snaps to a neighbour's edge.
    private static let snapPoints: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("layouts.editor.name", text: $draft.name)
                        .textFieldStyle(.roundedBorder)

                    presetStrip

                    canvasHeader
                    canvas
                    slotChips
                    selectionControls

                    optionsSection
                }
                .padding()
            }

            Divider()
            HStack {
                Spacer()
                Button("settings.action.cancel", action: onCancel)
                Button("settings.action.save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(12)
        }
    }

    // MARK: - Slots

    /// Current geometry — see the type doc comment.
    private var slots: [FreeformSlot] {
        if let freeform = draft.freeformSlots, !freeform.isEmpty { return freeform }
        return draft.toLayout().slots.enumerated().map { index, slot in
            FreeformSlot(id: Self.stableID(index), rect: slot.rect)
        }
    }

    private static func stableID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index)) ?? UUID()
    }

    /// Writes new geometry. The first call converts a template/tree layout to
    /// freeform slots.
    private func setSlots(_ new: [FreeformSlot]) {
        draft.freeformSlots = new
        draft.customTree = nil
    }

    private func updateSlot(_ id: UUID, to rect: CGRect) {
        var arr = slots
        guard let idx = arr.firstIndex(where: { $0.id == id }) else { return }
        arr[idx] = FreeformSlot(id: id, rect: rect).clamped()
        setSlots(arr)
    }

    private func slotNumber(_ id: UUID) -> Int? {
        slots.firstIndex(where: { $0.id == id }).map { $0 + 1 }
    }

    // MARK: - Presets

    private var presetStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("layouts.editor.presets")
                .font(.caption)
                .bold()
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(LayoutTemplate.allCases, id: \.self) { template in
                        Button {
                            applyPreset(template)
                        } label: {
                            VStack(spacing: 3) {
                                PresetThumbnail(template: template)
                                    .frame(width: 44, height: 28)
                                Text(Self.displayName(template))
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .frame(width: 64)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func applyPreset(_ template: LayoutTemplate) {
        let seeded = template.slots(proportions: template.defaultProportions)
            .map { FreeformSlot(rect: $0.rect).clamped() }
        setSlots(seeded)
        selectedID = nil
    }

    // MARK: - Canvas

    private var canvasHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                .controlSize(.small)
            }
            HStack(spacing: 12) {
                Toggle("layouts.editor.snap", isOn: $snapToEdges)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Spacer()
                if NSScreen.screens.count > 1 {
                    Picker("layouts.editor.preview_screen", selection: $previewScreenIndex) {
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                            Text(screen.localizedName).tag(index)
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                Text(aspectLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewScreen: NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        return screens[min(max(previewScreenIndex, 0), screens.count - 1)]
    }

    /// Width / height of the preview screen's tiling area, so a 21:9 display
    /// is drawn 21:9 instead of the same arbitrary rectangle for everything.
    private var aspectRatio: CGFloat {
        guard let frame = previewScreen?.visibleFrame, frame.width > 0, frame.height > 0 else { return 16.0 / 10.0 }
        return frame.width / frame.height
    }

    private var aspectLabel: String {
        let known: [(String, CGFloat)] = [
            ("16:9", 16.0 / 9), ("16:10", 16.0 / 10), ("21:9", 21.0 / 9), ("32:9", 32.0 / 9),
            ("4:3", 4.0 / 3), ("3:2", 3.0 / 2), ("5:4", 5.0 / 4), ("12:5", 12.0 / 5),
        ]
        if let match = known.min(by: { abs($0.1 - aspectRatio) < abs($1.1 - aspectRatio) }),
           abs(match.1 - aspectRatio) / match.1 < 0.04 {
            return match.0
        }
        return String(format: "%.2f:1", aspectRatio)
    }

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedID = nil }

                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    slotBody(slot, number: index + 1, size: size)
                }

                if let selected = slots.first(where: { $0.id == selectedID }) {
                    selectionOverlay(for: selected, size: size)
                }
            }
            .coordinateSpace(.named(Self.canvasSpace))
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        // Not clipped: handles on a slot that touches the canvas border
        // straddle it, and a clip would cut their grab area in half. The
        // padding leaves room for that overhang instead.
        .padding(Self.grab / 2)
    }

    private func absolute(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
               width: rect.width * size.width, height: rect.height * size.height)
    }

    private func slotBody(_ slot: FreeformSlot, number: Int, size: CGSize) -> some View {
        let abs = absolute(slot.rect, in: size)
        let isSelected = slot.id == selectedID
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.accentColor.opacity(isSelected ? 0.30 : 0.14))
                .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(isSelected ? 1 : 0.7), lineWidth: 1))
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .frame(width: 18, height: 18)
                .background(Circle().fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.18)))
                .padding(4)
        }
        .frame(width: max(1, abs.width), height: max(1, abs.height))
        .contentShape(Rectangle())
        .onTapGesture { selectedID = slot.id }
        .gesture(moveGesture(for: slot, size: size))
        .offset(x: abs.minX, y: abs.minY)
    }

    // MARK: Selection overlay (handles)

    private func selectionOverlay(for slot: FreeformSlot, size: CGSize) -> some View {
        let abs = absolute(slot.rect, in: size)
        let g = Self.grab
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                .background(Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 0.5).padding(1.5))
                .frame(width: max(1, abs.width), height: max(1, abs.height))
                .shadow(color: Color.accentColor.opacity(0.45), radius: 6)
                .offset(x: abs.minX, y: abs.minY)
                .allowsHitTesting(false)

            // Edges first, corners last so corners win where they meet.
            edgeHandle(.top, slot: slot, abs: abs, size: size)
            edgeHandle(.bottom, slot: slot, abs: abs, size: size)
            edgeHandle(.left, slot: slot, abs: abs, size: size)
            edgeHandle(.right, slot: slot, abs: abs, size: size)
            cornerHandle(.topLeft, slot: slot, point: CGPoint(x: abs.minX, y: abs.minY), g: g, size: size)
            cornerHandle(.topRight, slot: slot, point: CGPoint(x: abs.maxX, y: abs.minY), g: g, size: size)
            cornerHandle(.bottomLeft, slot: slot, point: CGPoint(x: abs.minX, y: abs.maxY), g: g, size: size)
            cornerHandle(.bottomRight, slot: slot, point: CGPoint(x: abs.maxX, y: abs.maxY), g: g, size: size)
        }
    }

    private enum Edge { case top, bottom, left, right }
    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func edgeHandle(_ edge: Edge, slot: FreeformSlot, abs: CGRect, size: CGSize) -> some View {
        let g = Self.grab
        let horizontal = edge == .top || edge == .bottom
        // Stop short of the corners so the corner handles keep their grab area.
        let length = max(4, (horizontal ? abs.width : abs.height) - g)
        let center: CGPoint
        switch edge {
        case .top:    center = CGPoint(x: abs.midX, y: abs.minY)
        case .bottom: center = CGPoint(x: abs.midX, y: abs.maxY)
        case .left:   center = CGPoint(x: abs.minX, y: abs.midY)
        case .right:  center = CGPoint(x: abs.maxX, y: abs.midY)
        }
        let w = horizontal ? length : g
        let h = horizontal ? g : length
        return Rectangle()
            .fill(Color.clear)
            .overlay(
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: horizontal ? min(36, length) : 4, height: horizontal ? 4 : min(36, length))
            )
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .offset(x: center.x - w / 2, y: center.y - h / 2)
            .gesture(resizeGesture(slot: slot, size: size) { rect, dx, dy in
                switch edge {
                case .top:    return CGRect(x: rect.minX, y: rect.minY + dy, width: rect.width, height: rect.height - dy)
                case .bottom: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + dy)
                case .left:   return CGRect(x: rect.minX + dx, y: rect.minY, width: rect.width - dx, height: rect.height)
                case .right:  return CGRect(x: rect.minX, y: rect.minY, width: rect.width + dx, height: rect.height)
                }
            })
            .onHover { inside in
                if inside {
                    (horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private func cornerHandle(_ corner: Corner, slot: FreeformSlot, point: CGPoint, g: CGFloat, size: CGSize) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: 12, height: 12)
            .frame(width: g, height: g)
            .contentShape(Rectangle())
            .offset(x: point.x - g / 2, y: point.y - g / 2)
            .gesture(resizeGesture(slot: slot, size: size) { rect, dx, dy in
                switch corner {
                case .topLeft:     return CGRect(x: rect.minX + dx, y: rect.minY + dy, width: rect.width - dx, height: rect.height - dy)
                case .topRight:    return CGRect(x: rect.minX, y: rect.minY + dy, width: rect.width + dx, height: rect.height - dy)
                case .bottomLeft:  return CGRect(x: rect.minX + dx, y: rect.minY, width: rect.width - dx, height: rect.height + dy)
                case .bottomRight: return CGRect(x: rect.minX, y: rect.minY, width: rect.width + dx, height: rect.height + dy)
                }
            })
            .onHover { inside in
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
    }

    // MARK: Gestures

    private func moveGesture(for slot: FreeformSlot, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                if dragOrigin?.id != slot.id {
                    dragOrigin = DragOrigin(id: slot.id, rect: slot.rect)
                    selectedID = slot.id
                }
                guard let origin = dragOrigin else { return }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                var rect = origin.rect.offsetBy(dx: dx, dy: dy)
                // Keep the size fixed at the canvas boundary: stop, don't squash.
                rect.origin.x = min(max(rect.minX, 0), 1 - rect.width)
                rect.origin.y = min(max(rect.minY, 0), 1 - rect.height)
                if snapToEdges {
                    rect.origin.x += snapDelta(
                        probes: [rect.minX, rect.maxX], candidates: xCandidates(excluding: slot.id), axisPoints: size.width
                    )
                    rect.origin.y += snapDelta(
                        probes: [rect.minY, rect.maxY], candidates: yCandidates(excluding: slot.id), axisPoints: size.height
                    )
                    rect.origin.x = min(max(rect.minX, 0), 1 - rect.width)
                    rect.origin.y = min(max(rect.minY, 0), 1 - rect.height)
                }
                updateSlot(slot.id, to: rect)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// `transform` receives the slot's ORIGINAL rect plus the translation (in
    /// unit space) and returns the unresized-by-clamp candidate rect.
    private func resizeGesture(
        slot: FreeformSlot,
        size: CGSize,
        transform: @escaping (CGRect, CGFloat, CGFloat) -> CGRect
    ) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                if dragOrigin?.id != slot.id {
                    dragOrigin = DragOrigin(id: slot.id, rect: slot.rect)
                    selectedID = slot.id
                }
                guard let origin = dragOrigin else { return }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                var rect = transform(origin.rect, dx, dy)
                if snapToEdges {
                    rect = snapResized(rect, original: origin.rect, excluding: slot.id, size: size)
                }
                updateSlot(slot.id, to: rect)
            }
            .onEnded { _ in dragOrigin = nil }
    }

    // MARK: Snapping

    private func xCandidates(excluding id: UUID) -> [CGFloat] {
        [0, 1] + slots.filter { $0.id != id }.flatMap { [$0.rect.minX, $0.rect.maxX] }
    }

    private func yCandidates(excluding id: UUID) -> [CGFloat] {
        [0, 1] + slots.filter { $0.id != id }.flatMap { [$0.rect.minY, $0.rect.maxY] }
    }

    /// Smallest adjustment that lands one of `probes` on one of `candidates`,
    /// or 0 when nothing is within the snap distance.
    private func snapDelta(probes: [CGFloat], candidates: [CGFloat], axisPoints: CGFloat) -> CGFloat {
        guard axisPoints > 0 else { return 0 }
        let threshold = Self.snapPoints / axisPoints
        var best: CGFloat = 0
        var bestDistance = threshold
        for probe in probes {
            for candidate in candidates {
                let delta = candidate - probe
                if abs(delta) < bestDistance {
                    bestDistance = abs(delta)
                    best = delta
                }
            }
        }
        return best
    }

    /// Snaps only the edge(s) that actually moved during a resize.
    private func snapResized(_ rect: CGRect, original: CGRect, excluding id: UUID, size: CGSize) -> CGRect {
        let xs = xCandidates(excluding: id)
        let ys = yCandidates(excluding: id)
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if abs(rect.minX - original.minX) > 0.0001 { minX += snapDelta(probes: [minX], candidates: xs, axisPoints: size.width) }
        if abs(rect.maxX - original.maxX) > 0.0001 { maxX += snapDelta(probes: [maxX], candidates: xs, axisPoints: size.width) }
        if abs(rect.minY - original.minY) > 0.0001 { minY += snapDelta(probes: [minY], candidates: ys, axisPoints: size.height) }
        if abs(rect.maxY - original.maxY) > 0.0001 { maxY += snapDelta(probes: [maxY], candidates: ys, axisPoints: size.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Slot chips & selection controls

    private var slotChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    let isSelected = slot.id == selectedID
                    Button {
                        selectedID = slot.id
                    } label: {
                        Text(String(format: String(localized: "layouts.editor.slot_n"), index + 1))
                            .font(.caption)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: isSelected ? 1.5 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var selectionControls: some View {
        if let id = selectedID, let number = slotNumber(id) {
            HStack(spacing: 8) {
                Text(String(format: String(localized: "layouts.editor.selected_n"), number))
                    .font(.callout)
                    .bold()
                Spacer()
                Button { bringToFront(id) } label: {
                    Label("layouts.freeform.bring_to_front", systemImage: "square.stack.3d.up")
                }
                Button { sendToBack(id) } label: {
                    Label("layouts.freeform.send_to_back", systemImage: "square.stack.3d.down")
                }
                if slots.count > 1 {
                    Button(role: .destructive) { delete(id) } label: {
                        Label("layouts.custom.delete_slot", systemImage: "trash")
                    }
                }
            }
            .controlSize(.small)
        } else {
            Text("layouts.editor.canvas_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// New slots cascade diagonally so repeated adds land somewhere visible
    /// rather than stacking exactly on top of the previous one.
    private func addSlot() {
        var arr = slots
        let step = CGFloat(arr.count % 5) * 0.05
        let new = FreeformSlot(rect: CGRect(x: 0.25 + step, y: 0.25 + step, width: 0.4, height: 0.4)).clamped()
        arr.append(new)
        setSlots(arr)
        selectedID = new.id
    }

    private func bringToFront(_ id: UUID) {
        var arr = slots
        guard let idx = arr.firstIndex(where: { $0.id == id }) else { return }
        arr.append(arr.remove(at: idx))
        setSlots(arr)
    }

    private func sendToBack(_ id: UUID) {
        var arr = slots
        guard let idx = arr.firstIndex(where: { $0.id == id }) else { return }
        arr.insert(arr.remove(at: idx), at: 0)
        setSlots(arr)
    }

    private func delete(_ id: UUID) {
        var arr = slots
        guard arr.count > 1 else { return }
        arr.removeAll { $0.id == id }
        setSlots(arr)
        if selectedID == id { selectedID = nil }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Toggle("layouts.editor.quick_picker.show", isOn: $draft.showInQuickPicker)
            Text("layouts.editor.quick_picker.hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("layouts.editor.apply_all_screens", isOn: $draft.applyToAllScreens)
            Text("layouts.editor.apply_all_screens.hint")
                .font(.caption)
                .foregroundStyle(.secondary)

            HotkeyField(chord: $draft.hotkey, label: "layouts.editor.hotkey", validate: validateHotkey)
        }
    }

    /// Refuses a chord already bound to another layout, a workspace, the Quick
    /// Picker, or the Dim toggle (the store would reject the first two at save
    /// time anyway; this just says so up front).
    private func validateHotkey(_ binding: HotkeyBinding) -> String? {
        let format = String(localized: "hotkeys.conflict")
        if let other = layoutVM.layouts.first(where: { $0.id != draft.id && $0.hotkey == binding }) {
            return String(format: format, other.name)
        }
        if let workspace = workspaceVM.workspaces.first(where: { $0.hotkey == binding }) {
            return String(format: format, workspace.name)
        }
        if settingsVM.quickPickerHotkey == binding {
            return String(format: format, String(localized: "hotkeys.quick_picker.label"))
        }
        if settingsVM.spotlight.hotkey == binding {
            return String(format: format, String(localized: "interaction.spotlight.hotkey"))
        }
        if settingsVM.spotlight.browserChromeHotkey == binding {
            return String(format: format, String(localized: "interaction.spotlight.chrome_hotkey"))
        }
        return nil
    }

    // MARK: - Names

    static func displayName(_ tpl: LayoutTemplate) -> String {
        switch tpl {
        case .single:        return String(localized: "layouts.template.single")
        case .twoCol:        return String(localized: "layouts.template.two_col")
        case .threeCol:      return String(localized: "layouts.template.three_col")
        case .twoRow:        return String(localized: "layouts.template.two_row")
        case .threeRow:      return String(localized: "layouts.template.three_row")
        case .grid2x2:       return String(localized: "layouts.template.grid_2x2")
        case .grid3x2:       return String(localized: "layouts.template.grid_3x2")
        case .lShapeLeft:    return String(localized: "layouts.template.l_left")
        case .lShapeRight:   return String(localized: "layouts.template.l_right")
        case .lShapeTop:     return String(localized: "layouts.template.l_top")
        case .lShapeBottom:  return String(localized: "layouts.template.l_bottom")
        }
    }
}

/// Tiny preview of a `LayoutTemplate`'s default proportions.
private struct PresetThumbnail: View {
    let template: LayoutTemplate

    var body: some View {
        Canvas { context, canvasSize in
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: canvasSize), cornerRadius: 3),
                         with: .color(.primary.opacity(0.07)))
            for slot in template.slots(proportions: template.defaultProportions) {
                let r = slot.rect
                let rect = CGRect(x: r.minX * canvasSize.width, y: r.minY * canvasSize.height,
                                  width: r.width * canvasSize.width, height: r.height * canvasSize.height)
                    .insetBy(dx: 0.75, dy: 0.75)
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.accentColor.opacity(0.35)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.accentColor), lineWidth: 1)
            }
        }
    }
}
