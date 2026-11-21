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

    /// One big "Focus Mode (Dimming)" block holding two separate sections:
    /// Apps Dimming and Browser Tab Bar Dimming.
    private var spotlightCard: some View {
        card("interaction.spotlight.section") {
            appsDimmingSection
            tabBarSection
        }
    }

    private var appsDimmingSection: some View {
        let dim = settingsVM.spotlight
        return sectionBox("interaction.apps.section") {
            HStack(spacing: 8) {
                DimTileButton(
                    title: dim.enabled ? "menu.dim.on" : "menu.dim.off",
                    systemImage: "moon.fill", isOn: dim.enabled, help: "menu.dim.help",
                    action: { var c = settingsVM.spotlight; c.enabled.toggle(); try? settingsVM.store.setSpotlight(c) }
                )
                // Stays highlighted whenever Dim is on, whichever mode is chosen.
                DimTileButton(
                    title: dim.exclusionMode == .perMonitor ? "menu.dim.mode.local" : "menu.dim.mode.global",
                    systemImage: "rectangle.on.rectangle", isOn: dim.enabled, help: "menu.dim.mode.help",
                    action: { var c = settingsVM.spotlight; c.exclusionMode = c.exclusionMode == .single ? .perMonitor : .single; try? settingsVM.store.setSpotlight(c) }
                )
            }
            Text(dim.exclusionMode == .perMonitor ? "menu.dim.mode.local.detail" : "menu.dim.mode.global.detail")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HotkeyField(
                chord: spotlightBinding(\.hotkey),
                label: "interaction.apps.shortcut",
                validate: { validateDimHotkey($0, slot: .dim) }
            )

            uniformSlider("interaction.spotlight.darkness", value: spotlightBinding(\.darkness),
                          range: SpotlightConfig.minDarkness...SpotlightConfig.maxDarkness, step: 0.07,
                          minLabel: "interaction.spotlight.darkness.min", maxLabel: "interaction.spotlight.darkness.max",
                          valueText: String(Int(((dim.darkness - SpotlightConfig.minDarkness) / 0.07).rounded())))

            HStack(spacing: 8) {
                Text("interaction.spotlight.blur").frame(width: 150, alignment: .leading)
                Picker("", selection: spotlightBinding(\.blurPreset)) {
                    Text("interaction.spotlight.blur.off").tag(SpotlightBlurPreset.off)
                    Text("interaction.spotlight.blur.light").tag(SpotlightBlurPreset.light)
                    Text("interaction.spotlight.blur.heavy").tag(SpotlightBlurPreset.heavy)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            uniformSlider("interaction.spotlight.delay", value: spotlightBinding(\.idleDelaySeconds),
                          range: SpotlightConfig.minIdleDelaySeconds...SpotlightConfig.maxIdleDelaySeconds, step: 1,
                          minLabel: "interaction.spotlight.delay.min", maxLabel: "interaction.spotlight.delay.max",
                          valueText: String(format: "%.1fs", dim.idleDelaySeconds))
            uniformSlider("interaction.spotlight.speed", value: fadeSecondsBinding(\.speed),
                          range: 0.5...5, step: 0.5,
                          minLabel: "interaction.spotlight.delay.min", maxLabel: "interaction.spotlight.delay.max",
                          valueText: String(format: "%.1fs", SpotlightConfig.fadeBaseSeconds / max(dim.speed, 0.01)))

            Divider()

            AppPickerView(
                bundleIDs: spotlightBinding(\.exceptionBundleIDs),
                label: "interaction.spotlight.exceptions.label",
                compact: true
            )
        }
    }

    private enum TabBarState { case on, lite, off }

    private func setTabBarState(_ state: TabBarState) {
        var c = settingsVM.spotlight
        c.dimBrowserChrome = state != .off
        c.browserChromeLight = state == .lite
        try? settingsVM.store.setSpotlight(c)
    }

    private var tabBarSection: some View {
        let dim = settingsVM.spotlight
        let current: TabBarState = !dim.dimBrowserChrome ? .off : (dim.browserChromeLight ? .lite : .on)
        let off = current == .off
        return sectionBox("interaction.chrome.section") {
            HStack(spacing: 8) {
                DimTileButton(title: "interaction.chrome.state.on", systemImage: "macwindow", isOn: current == .on,
                              help: "menu.dim.tabs.help", action: { setTabBarState(.on) })
                DimTileButton(title: "interaction.chrome.state.lite", systemImage: "macwindow", isOn: current == .lite,
                              help: "menu.dim.tabs.help", action: { setTabBarState(.lite) })
                DimTileButton(title: "interaction.chrome.state.off", systemImage: "macwindow", isOn: current == .off,
                              help: "menu.dim.tabs.help", action: { setTabBarState(.off) })
            }

            HotkeyField(
                chord: spotlightBinding(\.browserChromeHotkey),
                label: "interaction.chrome.shortcut",
                validate: { validateDimHotkey($0, slot: .browserChrome) }
            )

            Group {
                levelSlider("interaction.spotlight.chrome.darkness", value: spotlightBinding(\.browserChromeDarkness),
                            minLabel: "interaction.spotlight.darkness.min", maxLabel: "interaction.spotlight.darkness.max")
                levelSlider("interaction.spotlight.chrome.blur", value: spotlightBinding(\.browserChromeBlurRadius),
                            minLabel: "interaction.spotlight.blur.off", maxLabel: "interaction.spotlight.blur.strong")
                levelSlider("interaction.spotlight.chrome.light.darkness", value: spotlightBinding(\.browserChromeLightDarkness),
                            minLabel: "interaction.spotlight.darkness.min", maxLabel: "interaction.spotlight.darkness.max")
                levelSlider("interaction.spotlight.chrome.light.blur", value: spotlightBinding(\.browserChromeLightBlurRadius),
                            minLabel: "interaction.spotlight.blur.off", maxLabel: "interaction.spotlight.blur.strong")
                uniformSlider("interaction.spotlight.chrome.delay", value: spotlightBinding(\.browserChromeDelaySeconds),
                              range: SpotlightConfig.minIdleDelaySeconds...SpotlightConfig.maxIdleDelaySeconds, step: 1,
                              minLabel: "interaction.spotlight.delay.min", maxLabel: "interaction.spotlight.delay.max",
                              valueText: String(format: "%.1fs", dim.browserChromeDelaySeconds))
                uniformSlider("interaction.spotlight.chrome.speed", value: fadeSecondsBinding(\.browserChromeSpeed),
                              range: 0.5...5, step: 0.5,
                              minLabel: "interaction.spotlight.delay.min", maxLabel: "interaction.spotlight.delay.max",
                              valueText: String(format: "%.1fs", SpotlightConfig.fadeBaseSeconds / max(dim.browserChromeSpeed, 0.01)))
            }
            .disabled(off)

            Divider()

            HStack(spacing: 8) {
                Text("interaction.spotlight.chrome.mode").frame(width: 150, alignment: .leading)
                Picker("", selection: spotlightBinding(\.browserChromeMode)) {
                    Text("interaction.spotlight.chrome.mode.auto").tag(SpotlightChromeMode.automatic)
                    Text("interaction.spotlight.chrome.mode.fixed").tag(SpotlightChromeMode.fixedHeight)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                Button("interaction.spotlight.chrome.test") { runChromeTest() }
                    .controlSize(.small)
                    .disabled(isTestingChrome)
                if isTestingChrome { ProgressView().controlSize(.small) }
                Spacer()
            }

            if dim.browserChromeMode == .fixedHeight {
                uniformSlider("interaction.spotlight.chrome.height", value: spotlightBinding(\.browserChromeHeight),
                              range: SpotlightConfig.minChromeHeight...SpotlightConfig.maxChromeHeight, step: 18,
                              minLabel: "interaction.spotlight.chrome.height.min", maxLabel: "interaction.spotlight.chrome.height.max",
                              valueText: String(Int(dim.browserChromeHeight)))
            }
            if let chromeTestResult {
                Text(chromeTestResult)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("interaction.spotlight.dim_browser_chrome.hint")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// A titled section box (second-level heading) inside a bigger card.
    @ViewBuilder
    private func sectionBox<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
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
        compact: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(compact ? .subheadline : .title2)
                    .bold()
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(compact ? 12 : 18)
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
    /// A labelled slider whose label, end captions and value readout have fixed
    /// widths, so every slider's track is the same length and every one looks
    /// the same. `step` defaults to 1/20 of the range.
    private func uniformSlider(
        _ label: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        minLabel: LocalizedStringKey,
        maxLabel: LocalizedStringKey,
        valueText: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 150, alignment: .leading)
            Text(minLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Slider(value: value, in: range, step: step ?? (range.upperBound - range.lowerBound) / 20)
                .frame(maxWidth: .infinity)
            Text(maxLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            Text(valueText ?? "")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// 0-10 level slider used by every top-bar darkness/blur setting, so
    /// the normal and Lite modes share one scale.
    private func levelSlider(
        _ label: LocalizedStringKey,
        value: Binding<Double>,
        minLabel: LocalizedStringKey,
        maxLabel: LocalizedStringKey
    ) -> some View {
        uniformSlider(label, value: value, range: 0...SpotlightConfig.maxChromeLevel, step: 1,
                      minLabel: minLabel, maxLabel: maxLabel, valueText: String(Int(value.wrappedValue.rounded())))
    }

    /// Shows a fade as seconds (`fadeBaseSeconds / speed`) while the config
    /// keeps storing the speed multiplier.
    private func fadeSecondsBinding(_ keyPath: WritableKeyPath<SpotlightConfig, Double>) -> Binding<Double> {
        Binding(
            get: { SpotlightConfig.fadeBaseSeconds / max(settingsVM.spotlight[keyPath: keyPath], 0.01) },
            set: { seconds in
                var config = settingsVM.spotlight
                config[keyPath: keyPath] = SpotlightConfig.fadeBaseSeconds / max(seconds, 0.05)
                try? settingsVM.store.setSpotlight(config)
            }
        )
    }

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

    private enum DimHotkeySlot { case dim, browserChrome }

    /// Refuses a chord already bound to a layout, a workspace, the Quick
    /// Picker, or the OTHER Dim hotkey — otherwise the later registration
    /// would silently lose.
    private func validateDimHotkey(_ binding: HotkeyBinding, slot: DimHotkeySlot) -> String? {
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
        switch slot {
        case .dim where settingsVM.spotlight.browserChromeHotkey == binding:
            return String(format: format, String(localized: "interaction.spotlight.chrome_hotkey"))
        case .browserChrome where settingsVM.spotlight.hotkey == binding:
            return String(format: format, String(localized: "interaction.spotlight.hotkey"))
        default:
            return nil
        }
    }

    private func label(for curve: EasingCurve) -> String {
        switch curve {
        case .linear:  return String(localized: "interaction.animation.easing.linear")
        case .easeOut: return String(localized: "interaction.animation.easing.ease_out")
        case .spring:  return String(localized: "interaction.animation.easing.spring")
        }
    }
}
