import SwiftUI

struct SettingsSection<Rows: View>: View {
    let title: String
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.tertiary)
                .padding(.leading, 8)
            VStack(spacing: 1) { rows() }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
        }
    }
}

struct SettingsToggleRow: View {
    let symbol: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).frame(width: 16)
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white)
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 8).frame(height: 26)
    }
}

struct SettingsActionRow: View {
    let symbol: String
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).frame(width: 16)
                Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.4 : 1)
    }
}
