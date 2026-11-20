import SwiftUI
import SceneCore

/// Compact chord-capture field. Wraps the existing V0.2 `HotkeyCaptureView`
/// (which uses a callback-style NSView) and adapts it to a
/// `@Binding var chord: HotkeyBinding?` surface.
///
/// `validate` lets a call site reject a captured chord (e.g. one already
/// bound to a layout or workspace) before it's written: return a message to
/// refuse it, `nil` to accept.
struct HotkeyField: View {
    @Binding var chord: HotkeyBinding?
    var label: LocalizedStringKey
    var validate: ((HotkeyBinding) -> String?)?
    @State private var recording: Bool = false
    @State private var errorMessage: String?

    init(
        chord: Binding<HotkeyBinding?>,
        label: LocalizedStringKey = "workspace.editor.hotkey",
        validate: ((HotkeyBinding) -> String?)? = nil
    ) {
        self._chord = chord
        self.label = label
        self.validate = validate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).frame(width: 120, alignment: .leading)
                if recording {
                    HotkeyCaptureView { binding in
                        recording = false
                        if let message = validate?(binding) {
                            errorMessage = message
                        } else {
                            errorMessage = nil
                            chord = binding
                        }
                    }
                    .frame(height: 24)
                } else {
                    Text(chord?.displayString ?? String(localized: "workspace.editor.hotkey.none"))
                        .frame(minWidth: 80, alignment: .leading)
                        .foregroundStyle(chord == nil ? .secondary : .primary)
                }
                Spacer()
                Button(recording ? "workspace.editor.hotkey.cancel" : "workspace.editor.hotkey.record") {
                    recording.toggle()
                }
                Button("workspace.editor.hotkey.clear") {
                    chord = nil
                    recording = false
                    errorMessage = nil
                }
                .disabled(chord == nil)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
