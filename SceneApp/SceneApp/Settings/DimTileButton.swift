import SwiftUI

/// The rounded on/off tile used for Dim controls, shared by the menu bar and
/// Settings so both look identical. A tile's title says its CURRENT state
/// (e.g. "Dim: On"), and it is highlighted while `isOn`.
struct DimTileButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title).lineLimit(1)
            }
            .font(.callout)
            .fontWeight(isOn ? .semibold : .regular)
            .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isOn ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
