import SwiftUI

/// Hover-highlighted row for the window-style menu bar panel. Mimics native
/// menu-item affordances (rounded highlight, dimmed-when-disabled) since the
/// panel renders plain SwiftUI buttons, not NSMenuItems.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovering && isEnabled ? Color.primary.opacity(0.1) : Color.clear)
                )
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1.0) : 0.4)
                .onHover { hovering = $0 }
        }
    }
}
