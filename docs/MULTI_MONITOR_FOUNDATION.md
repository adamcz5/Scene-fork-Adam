# Multi-Monitor Foundation

Personal architecture requirement for this fork: Scene must be designed from
the ground up to support multiple physical displays — MacBook + external,
multiple externals, mixed sizes/resolutions, arbitrary relative positions,
and connect/disconnect at any time. No assuming one display, a "primary"
display, a fixed resolution, or a fixed arrangement. All layout coordinates
are calculated relative to the *target display*, not the whole desktop.

Target model:

```
Layout
  ├── Display A
  │     ├── Zone 1
  │     ├── Zone 2
  │     └── Zone 3
  └── Display B
        ├── Zone 1
        └── Zone 2
```

e.g.

```
Research:
    Chrome Work → External Monitor, zone 1
    Claude      → External Monitor, zone 2
    Slack       → MacBook display, zone 1
```

Minimum bar for "done":

1. Detect all connected displays.
2. Know which display each window currently belongs to.
3. Apply layouts relative to the correct display.
4. Preserve window placement when displays are rearranged.
5. Gracefully handle a display being disconnected.
6. Use the currently active display for the Scene popup.

Constraint: don't hard-code display IDs or positions — display identifiers
can change across reconnects. Use stable display information where possible,
and fall back gracefully when a previously configured display is gone.

This is foundational architecture, not necessarily a full first-release UI
feature — the model must not block a future "assign per-display layouts in
the UI" screen, even if v1 only exposes it indirectly.

## Audit against upstream (as merged into this fork)

The upstream `macbook-resizer` codebase already covers most of this — it's
further along than a blank slate:

| Requirement | Status | Where |
|---|---|---|
| 1. Detect all connected displays | ✅ | `ScreenResolver` wraps `NSScreen.screens`; `MonitorTriggerWatcher` diffs the snapshot on `NSApplication.didChangeScreenParametersNotification` |
| 2. Know which display a window belongs to | ✅ | `ScreenResolver.screenForWindow(_:)` — finds the screen containing the window's center point |
| 3. Apply layouts relative to the correct display | ✅ | `LayoutEngine.plan` takes `visibleFrame` for one target screen (via `TilingFrame.forScreen(screen)`); `Coordinator.performApplyLayout(_:on:from:)` takes an explicit `NSScreen` |
| 3b. Per-display layout within one "scene" (the `Layout → Display → Zones` tree above) | ✅ (workspace-level) | `Workspace.displayLayouts: [DisplayLayoutAssignment]` maps a display name → `layoutID`; `Workspace.resolvedLayoutID(forDisplay:)` resolves it. `DisplayLayoutsEditor` (Settings UI) already exposes assigning a layout per connected display within a Workspace. This *is* the nested model, just expressed as Workspace → per-display Layout(zones) rather than a single Layout object spanning displays. |
| 4. Preserve window placement across rearrangement | ✅ | `LayoutEngine.plan`'s sticky pass (10pt tolerance) keeps windows on their current slot on re-apply; `TilingFrame` unifies Dock-reserve math across screens so re-firing after a Dock move doesn't reshuffle everything |
| 5. Gracefully handle a display disconnecting | ✅ (partial) | `resolvedLayoutID(forDisplay:)` falls back to the workspace's default `layoutID` when the display name isn't found in `displayLayouts`. `MonitorTriggerWatcher` fires `.monitorDisconnect` for trigger-based reactions. |
| 6. Active display for the Scene popup | ⚠️ not explicitly verified | Menu-bar `NSStatusItem` popovers render on whatever screen owns the menu bar the icon lives on — not something Scene controls directly. Layout *application* already resolves the active screen via `ScreenResolver.activeScreen()` (under-mouse, falling back to `NSScreen.main`). |

### Real gap: display identity is a display **name**, not a stable ID

Every per-display mapping (`DisplayLayoutAssignment.displayName`, workspace
triggers' `monitorConnect(displayName:)`) keys off `NSScreen.localizedName`
— a human-readable string like `"LG UltraFine"`. This is *stable across
reconnects* (good — survives `CGDirectDisplayID` reshuffling, which is the
main failure mode the "don't hard-code display IDs" constraint is guarding
against) but **collides when two displays share a model name** — e.g. two
identical external monitors both report the same `localizedName`, so they
can't be distinguished for per-display layout assignment.

Not a blocker for the common case (MacBook + one external), but worth
tracking before leaning on this for symmetric multi-external setups. A
sturdier identity would combine `localizedName` with a position-invariant
signature (e.g. resolution + relative arrangement rank) or persist
`CGDisplayCreateUUIDFromDisplayID` per display and fall back to name-matching
when the UUID isn't found (exactly the "graceful fallback" the spec asks
for).

### Net takeaway

The foundational architecture this doc asked for already exists upstream —
no rewrite needed. Future work here should extend the existing
`Workspace.displayLayouts` / `DisplayLayoutsEditor` path rather than
introducing a parallel multi-display model.
