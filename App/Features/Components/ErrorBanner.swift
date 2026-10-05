import SwiftUI

/// Compact warning banner for partial failures (e.g. some addons failed). Optional retry action.
struct ErrorBanner: View {
    var title: String
    var messages: [String] = []
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Palette.warning)
                .frame(width: 34, height: 34)
                .background(Theme.Palette.warning.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                ForEach(Array(messages.enumerated()), id: \.offset) { _, m in
                    Text(m)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let retry {
                Button(action: retry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.ds(.secondary, compact: true))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.m, bottomLeadingRadius: Theme.Radius.m, style: .continuous)
                .fill(Theme.Palette.warning)
                .frame(width: 3)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.stroke))
    }
}
