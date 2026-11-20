import SwiftUI
import SceneCore

struct InteractionTab: View {
    @EnvironmentObject var settingsVM: SettingsStoreViewModel
    @EnvironmentObject var layoutVM: LayoutStoreViewModel
    @EnvironmentObject var workspaceVM: WorkspaceStoreViewModel
    let calendarPermissionRequester: () async -> Bool
    @State private var previewToggle: Bool = false
    @State private var triggersExpanded: Bool = false
    @State private var triggerWorkspaceID: UUID?
    @State private var triggerDraft: [WorkspaceTrigger] = []
    @State private var triggerSavedBaseline: [WorkspaceTrigger] = []
    @State private var triggerSaveError: String?
    @State private var chromeTestResult: String?
    @State private var isTestingChrome = false

    /// Replaced the earlier `Form { Section { ... } }` layout: on this
    /// window, `Form`'s native macOS section chrome rendered as plain
    /// running text with no visible box/border between sections (and no
    /// scrolling once content overflowed) — reported back as "I cannot
    /// scroll" / sections not reading as separate blocks. A plain
    /// `ScrollView` + explicitly-drawn `card`/`subBlock` boxes below
    /// guarantees both: scrolling is never in question, and every section
    /// (and, for the bigger ones, every sub-block within it) gets its own
    /// visible rounded box with a real title, not just an indent change.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                animationCard
                dragSwapCard
                appSwitcherCard
                spotlightCard
                workspaceTriggersCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var animationCard: some View {
        card("interaction.animation.section", hint: "interaction.animation.section.hint") {
            Toggle("interaction.animation.enable", isOn: enabledBinding)

            Picker("interaction.animation.easing", selection: easingBinding) {
                ForEach(EasingCurve.allCases, id: \.self) { curve in
                    Text(label(for: curve)).tag(curve)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!settingsVM.animation.enabled)

            VStack(alignment: .leading, spacing: 4) {
                Slider(value: durationBinding, in: 100...500, step: 25) {
                    Text("interaction.animation.duration")
                } minimumValueLabel: {
                    Text("interaction.animation.duration.min")
                } maximumValueLabel: {
                    Text("interaction.animation.duration.max")
                }
                .disabled(!settingsVM.animation.enabled)

                Text(String(format: String(localized: "interaction.animation.duration.value"), settingsVM.animation.durationMs))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            previewSection
        }
    }

    private var dragSwapCard: some View {
        card("interaction.drag_swap.section", hint: "interaction.drag_swap.section.hint") {
            subBlock("interaction.drag_swap.subsection.stickiness") {
                Picker("interaction.drag_swap.mode", selection: stickyModeBinding) {
                    Text("interaction.drag_swap.mode.off").tag(StickyModeOption.off)
                    Text("interaction.drag_swap.mode.always").tag(StickyModeOption.always)
                    Text("interaction.drag_swap.mode.timed").tag(StickyModeOption.timed)
                }
                .pickerStyle(.segmented)

                if stickyModeBinding.wrappedValue == .timed {
                    Slider(value: stickyDurationBinding, in: DragSwapConfig.minAutoDisableSeconds...DragSwapConfig.maxAutoDisableSeconds, step: 1) {
                        Text("interaction.drag_swap.mode.timed.duration")
                    } minimumValueLabel: {
                        Text("interaction.drag_swap.mode.timed.duration.min")
                    } maximumValueLabel: {
                        Text("interaction.drag_swap.mode.timed.duration.max")
                    }
                    Text(String(format: String(localized: "interaction.drag_swap.mode.timed.duration.value"), Int(stickyDurationBinding.wrappedValue)))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            subBlock("interaction.drag_swap.subsection.threshold") {
                Slider(value: dragSwapThresholdBinding, in: 10...100, step: 5) {
                    Text("interaction.drag_swap.threshold")
                } minimumValueLabel: {
                    Text("interaction.drag_swap.threshold.min")
                } maximumValueLabel: {
                    Text("interaction.drag_swap.threshold.max")
                }
                .disabled(!settingsVM.dragSwap.enabled)

                Text(String(format: String(localized: "interaction.drag_swap.threshold.value"), Int(settingsVM.dragSwap.distanceThresholdPt)))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Text("interaction.drag_swap.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appSwitcherCard: some View {
        card("interaction.app_switcher.section", hint: "interaction.app_switcher.section.hint") {
            Toggle("interaction.app_switcher.enable", isOn: appSwitcherEnabledBinding)
            AppSwitcherEntriesEditor(entries: appSwitcherEntriesBinding)
            Text("interaction.app_switcher.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Spotlight (dim) card. Everything here is a plain on/off or a single
    /// slider/picker — no setting overrides another.
    private var spotlightCard: some View {
        card("interaction.spotlight.section", hint: "interaction.spotlight.section.hint") {
            Toggle("interaction.spotlight.enable", isOn: spotlightBinding(\.enabled))

            Toggle("interaction.spotlight.per_monitor", isOn: perMonitorBinding)
                .disabled(!settingsVM.spotlight.enabled)
            Text("interaction.spotlight.per_monitor.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)

            subBlock("interaction.spotlight.subsection.look") {
                Slider(
                    value: spotlightBinding(\.darkness),
                    in: SpotlightConfig.minDarkness...SpotlightConfig.maxDarkness,
                    step: 0.05
                ) {
                    Text("interaction.spotlight.darkness")
                } minimumValueLabel: {
                    Text("interaction.spotlight.darkness.min")
                } maximumValueLabel: {
                    Text("interaction.spotlight.darkness.max")
                }
                .disabled(!settingsVM.spotlight.enabled)

                Picker("interaction.spotlight.blur", selection: spotlightBinding(\.blurPreset)) {
                    Text("interaction.spotlight.blur.off").tag(SpotlightBlurPreset.off)
                    Text("interaction.spotlight.blur.light").tag(SpotlightBlurPreset.light)
                    Text("interaction.spotlight.blur.heavy").tag(SpotlightBlurPreset.heavy)
                }
                .pickerStyle(.segmented)
                .disabled(!settingsVM.spotlight.enabled)

                Slider(
                    value: spotlightBinding(\.speed),
                    in: SpotlightConfig.minSpeed...SpotlightConfig.maxSpeed,
                    step: 0.25
                ) {
                    Text("interaction.spotlight.speed")
                } minimumValueLabel: {
                    Text("interaction.spotlight.speed.min")
                } maximumValueLabel: {
                    Text("interaction.spotlight.speed.max")
                }
                .disabled(!settingsVM.spotlight.enabled)
            }

            subBlock("interaction.spotlight.subsection.delay", hint: "interaction.spotlight.delay.hint") {
                Slider(
                    value: spotlightBinding(\.idleDelaySeconds),
                    in: SpotlightConfig.minIdleDelaySeconds...SpotlightConfig.maxIdleDelaySeconds,
                    step: 0.5
                ) {
                    Text("interaction.spotlight.delay")
                } minimumValueLabel: {
                    Text("interaction.spotlight.delay.min")
                } maximumValueLabel: {
                    Text("interaction.spotlight.delay.max")
                }
                .disabled(!settingsVM.spotlight.enabled)

                Text(String(format: String(localized: "interaction.spotlight.delay.value"), settingsVM.spotlight.idleDelaySeconds))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            subBlock("interaction.spotlight.subsection.hotkey", hint: "interaction.spotlight.hotkey.hint") {
                HotkeyField(
                    chord: spotlightBinding(\.hotkey),
                    label: "interaction.spotlight.hotkey",
                    validate: validateSpotlightHotkey
                )
            }

            subBlock("interaction.spotlight.subsection.experimental", hint: "interaction.spotlight.dim_browser_chrome.hint") {
                Toggle("interaction.spotlight.dim_browser_chrome", isOn: spotlightBinding(\.dimBrowserChrome))
                    .disabled(!settingsVM.spotlight.enabled)

                if settingsVM.spotlight.dimBrowserChrome {
                    Picker("interaction.spotlight.chrome.mode", selection: spotlightBinding(\.browserChromeMode)) {
                        Text("interaction.spotlight.chrome.mode.auto").tag(SpotlightChromeMode.automatic)
                        Text("interaction.spotlight.chrome.mode.fixed").tag(SpotlightChromeMode.fixedHeight)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!settingsVM.spotlight.enabled)

                    if settingsVM.spotlight.browserChromeMode == .fixedHeight {
                        Slider(
                            value: spotlightBinding(\.browserChromeHeight),
                            in: SpotlightConfig.minChromeHeight...SpotlightConfig.maxChromeHeight,
                            step: 2
                        ) {
                            Text("interaction.spotlight.chrome.height")
                        } minimumValueLabel: {
                            Text("interaction.spotlight.chrome.height.min")
                        } maximumValueLabel: {
                            Text("interaction.spotlight.chrome.height.max")
                        }
                        Text(String(format: String(localized: "interaction.spotlight.chrome.height.value"), Int(settingsVM.spotlight.browserChromeHeight)))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    HStack(spacing: 8) {
                        Button("interaction.spotlight.chrome.test") { runChromeTest() }
                            .controlSize(.small)
                            .disabled(isTestingChrome)
                        if isTestingChrome {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let chromeTestResult {
                        Text(chromeTestResult)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("interaction.spotlight.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Reports what automatic detection finds in each open supported browser.
    /// Switches the browser's accessibility tree on first and waits a moment
    /// for it to fill in, so a first run isn't a false "not found".
    private func runChromeTest() {
        isTestingChrome = true
        chromeTestResult = nil
        for app in NSWorkspace.shared.runningApplications
        where BrowserChromeDetector.isCandidate(bundleID: app.bundleIdentifier) {
            BrowserChromeDetector.prepare(pid: app.processIdentifier)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            let detections = BrowserChromeDetector.detectRunningBrowsers()
            if detections.isEmpty {
                chromeTestResult = String(localized: "interaction.spotlight.chrome.test.none")
            } else {
                chromeTestResult = detections.map { detection in
                    if let height = detection.topBarHeight {
                        return String(format: String(localized: "interaction.spotlight.chrome.test.found"), detection.appName, Int(height))
                    }
                    return String(format: String(localized: "interaction.spotlight.chrome.test.not_found"), detection.appName)
                }.joined(separator: "\n")
            }
            isTestingChrome = false
        }
    }

    // MARK: - Workspace triggers (relocated from the Workspace editor)

    /// Automatic workspace activation (monitor connect/disconnect, time of
    /// day, calendar event). Edited here rather than in the Workspace editor to
    /// keep that form focused; collapsed by default since most people never
    /// touch it. The data still lives on each `Workspace`.
    private var workspaceTriggersCard: some View {
        card("interaction.triggers.section", hint: "interaction.triggers.section.hint") {
            DisclosureGroup("interaction.triggers.expand", isExpanded: $triggersExpanded) {
                if workspaceVM.workspaces.isEmpty {
                    Text("interaction.triggers.empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("interaction.triggers.workspace", selection: triggerWorkspaceBinding) {
                            ForEach(workspaceVM.workspaces) { workspace in
                                Text(workspace.name).tag(workspace.id)
                            }
                        }
                        WorkspaceTriggerEditor(
                            triggers: $triggerDraft,
                            calendarPermissionRequester: calendarPermissionRequester
                        )
                        if let triggerSaveError {
                            Text(triggerSaveError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        HStack {
                            Spacer()
                            if triggerDraft != triggerSavedBaseline {
                                Text("workspace.editor.unsaved")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("workspace.editor.save", action: saveTriggers)
                                .disabled(triggerDraft == triggerSavedBaseline)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .onAppear(perform: loadTriggerDraft)
        .onChange(of: workspaceVM.workspaces) { _, _ in loadTriggerDraft() }
    }

    private var effectiveTriggerWorkspaceID: UUID? {
        if let id = triggerWorkspaceID, workspaceVM.workspaces.contains(where: { $0.id == id }) { return id }
        return workspaceVM.workspaces.first?.id
    }

    private var triggerWorkspaceBinding: Binding<UUID> {
        Binding(
            get: { effectiveTriggerWorkspaceID ?? UUID() },
            set: { id in
                // Switching workspaces discards any unsaved edits to the
                // previous one, so reset both before reloading.
                triggerWorkspaceID = id
                triggerDraft = []
                triggerSavedBaseline = []
                loadTriggerDraft()
            }
        )
    }

    private func loadTriggerDraft() {
        guard let id = effectiveTriggerWorkspaceID,
              let workspace = workspaceVM.workspaces.first(where: { $0.id == id })
        else {
            triggerDraft = []
            triggerSavedBaseline = []
            return
        }
        // Don't clobber in-progress edits when an unrelated store change fires.
        if triggerDraft != triggerSavedBaseline { return }
        triggerDraft = workspace.triggers
        triggerSavedBaseline = workspace.triggers
        triggerSaveError = nil
    }

    private func saveTriggers() {
        guard let id = effectiveTriggerWorkspaceID,
              var workspace = workspaceVM.workspaces.first(where: { $0.id == id })
        else { return }
        workspace.triggers = triggerDraft
        do {
            try workspaceVM.update(workspace)
            triggerSavedBaseline = triggerDraft
            triggerSaveError = nil
        } catch {
            triggerSaveError = error.localizedDescription
        }
    }

    /// Top-level section box: title, optional hint, then whatever controls
    /// the caller passes — every card gets the same rounded, filled
    /// background so sections read as distinct blocks rather than a single
    /// continuous list.
    @ViewBuilder
    private func card<Content: View>(
        _ title: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3)
                    .bold()
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }

    /// Nested box inside a bigger card (Drag & Swap, Spotlight), for grouping
    /// one labeled axis of settings (e.g. "Stickiness" vs. "Drag Distance")
    /// so a card with several unrelated controls doesn't read as one list.
    @ViewBuilder
    private func subBlock<Content: View>(
        _ title: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .bold()
                .foregroundStyle(.secondary)
            content()
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var previewSection: some View {
        VStack(alignment: .leading) {
            Text("interaction.animation.preview").font(.headline)
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.05))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor)
                        .frame(width: 60, height: 30)
                        .offset(x: previewToggle ? geo.size.width - 70 : 10, y: 10)
                        .animation(swiftUIAnimation, value: previewToggle)
                }
            }
            .frame(height: 60)
            Button("interaction.animation.preview.run") { previewToggle.toggle() }
        }
        .padding(.vertical)
    }

    private var swiftUIAnimation: Animation {
        let dur = Double(settingsVM.animation.durationMs) / 1000.0
        switch settingsVM.animation.easing {
        case .linear:  return .linear(duration: dur)
        case .easeOut: return .easeOut(duration: dur)
        case .spring:  return .spring(duration: dur, bounce: 0.3)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.animation.enabled },
            set: { v in
                let c = settingsVM.animation
                try? settingsVM.store.setAnimation(AnimationConfig(enabled: v, durationMs: c.durationMs, easing: c.easing))
            }
        )
    }

    private var durationBinding: Binding<Double> {
        Binding(
            get: { Double(settingsVM.animation.durationMs) },
            set: { v in
                let c = settingsVM.animation
                try? settingsVM.store.setAnimation(AnimationConfig(enabled: c.enabled, durationMs: Int(v), easing: c.easing))
            }
        )
    }

    private var easingBinding: Binding<EasingCurve> {
        Binding(
            get: { settingsVM.animation.easing },
            set: { v in
                let c = settingsVM.animation
                try? settingsVM.store.setAnimation(AnimationConfig(enabled: c.enabled, durationMs: c.durationMs, easing: v))
            }
        )
    }

    /// Mirrors `MenuBarContentView`'s sticky-mode picker so Settings and the
    /// menu bar always agree on off / always / timed.
    private var stickyModeBinding: Binding<StickyModeOption> {
        Binding(
            get: { settingsVM.dragSwap.stickyModeOption },
            set: { settingsVM.dragSwap.applying($0, to: settingsVM.store) }
        )
    }

    private var stickyDurationBinding: Binding<Double> {
        Binding(
            get: { settingsVM.dragSwap.autoDisableAfterSeconds ?? DragSwapConfig.defaultAutoDisableSeconds },
            set: { v in
                let c = settingsVM.dragSwap
                try? settingsVM.store.setDragSwap(
                    DragSwapConfig(enabled: c.enabled, distanceThresholdPt: c.distanceThresholdPt, autoDisableAfterSeconds: v)
                )
            }
        )
    }

    private var dragSwapThresholdBinding: Binding<Double> {
        Binding(
            get: { Double(settingsVM.dragSwap.distanceThresholdPt) },
            set: { v in
                let c = settingsVM.dragSwap
                try? settingsVM.store.setDragSwap(
                    DragSwapConfig(enabled: c.enabled, distanceThresholdPt: CGFloat(v), autoDisableAfterSeconds: c.autoDisableAfterSeconds)
                )
            }
        )
    }

    private var appSwitcherEnabledBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.appSwitcher.enabled },
            set: { v in
                let c = settingsVM.appSwitcher
                try? settingsVM.store.setAppSwitcher(AppSwitcherConfig(enabled: v, entries: c.entries))
            }
        )
    }

    private var appSwitcherEntriesBinding: Binding<[AppSwitcherEntry]> {
        Binding(
            get: { settingsVM.appSwitcher.entries },
            set: { v in
                let c = settingsVM.appSwitcher
                try? settingsVM.store.setAppSwitcher(AppSwitcherConfig(enabled: c.enabled, entries: v))
            }
        )
    }

    /// Read/write binding to one field of `SpotlightConfig`. Edits a COPY of
    /// the current config and saves the whole thing, so every other field —
    /// including ones this view doesn't show — is always carried through.
    private func spotlightBinding<T>(_ keyPath: WritableKeyPath<SpotlightConfig, T>) -> Binding<T> {
        Binding(
            get: { settingsVM.spotlight[keyPath: keyPath] },
            set: { value in
                var config = settingsVM.spotlight
                config[keyPath: keyPath] = value
                try? settingsVM.store.setSpotlight(config)
            }
        )
    }

    private var perMonitorBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.spotlight.exclusionMode == .perMonitor },
            set: { on in
                var config = settingsVM.spotlight
                config.exclusionMode = on ? .perMonitor : .single
                try? settingsVM.store.setSpotlight(config)
            }
        )
    }

    /// Refuses a chord already bound to a layout, a workspace, or the Quick
    /// Picker — otherwise the later registration would silently lose.
    private func validateSpotlightHotkey(_ binding: HotkeyBinding) -> String? {
        let format = String(localized: "hotkeys.conflict")
        if let layout = layoutVM.layouts.first(where: { $0.hotkey == binding }) {
            return String(format: format, layout.name)
        }
        if let workspace = workspaceVM.workspaces.first(where: { $0.hotkey == binding }) {
            return String(format: format, workspace.name)
        }
        if settingsVM.quickPickerHotkey == binding {
            return String(format: format, String(localized: "hotkeys.quick_picker.label"))
        }
        return nil
    }

    private func label(for curve: EasingCurve) -> String {
        switch curve {
        case .linear:  return String(localized: "interaction.animation.easing.linear")
        case .easeOut: return String(localized: "interaction.animation.easing.ease_out")
        case .spring:  return String(localized: "interaction.animation.easing.spring")
        }
    }
}
