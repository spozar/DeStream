import SwiftUI

/// Storage page (iOS: pushed from Settings). macOS embeds `StorageSettingsCard` in the Settings page. OWNER: UI Agent 1.
struct StorageSettingsView: View {
    var body: some View {
        SettingsPage(title: "Storage", subtitle: "Saved titles and disk usage") {
            StorageSettingsCard()
        }
    }
}

/// Library size, free space and per-title sizes with delete.
struct StorageSettingsCard: View {
    @Environment(LibraryStore.self) private var library
    @State private var sizes: [String: Int64] = [:]
    @State private var freeSpace: Int64?
    @State private var hasMeasured = false
    @State private var pendingDelete: SavedTitle?
    @State private var errorMessage: String?

    var body: some View {
        SettingsCard(title: "Storage", systemImage: "internaldrive.fill") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: StorageMetrics.statSpacing) {
                    stat("Saved titles", "\(library.titles.count)", icon: "square.stack.fill")
                    stat("Library size", hasMeasured ? Self.format(sizes.values.reduce(0, +)) : "—", icon: "chart.pie.fill")
                    stat("Available", freeSpace.map(Self.format) ?? "—", icon: "internaldrive")
                }
                if let errorMessage {
                    StatusLine(kind: .error, text: errorMessage)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                VStack(spacing: 0) {
                    if library.titles.isEmpty {
                        Text("Nothing saved yet.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .padding(.vertical, Theme.Space.s)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Array(sortedTitles.enumerated()), id: \.element.id) { index, title in
                        StorageTitleRow(
                            name: title.meta.name,
                            summary: itemSummary(title),
                            size: sizes[title.id].map(Self.format) ?? "…",
                            divider: index > 0,
                            onDelete: { pendingDelete = title }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
                        ))
                    }
                }
            }
            .animation(SettingsMetrics.listSpring, value: sortedTitles.map(\.id))
            .animation(Theme.Motion.appear, value: errorMessage)
        }
        .task(id: library.titles.map(\.folder)) { await measure() }
        .confirmationDialog(
            "Delete \(pendingDelete?.meta.name ?? "title")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let title = pendingDelete else { return }
                pendingDelete = nil
                errorMessage = nil
                Task {
                    do { try await library.delete(title: title) } catch { errorMessage = error.localizedDescription }
                }
            }
        } message: {
            Text("All saved files for this title are permanently deleted from this device. This can't be undone.")
        }
    }

    private func stat(_ label: String, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.accentHover)
            Text(value)
                .font(.system(size: StorageMetrics.statValueSize, weight: .heavy).monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
                .animation(Theme.Motion.appear, value: value)
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(StorageMetrics.statPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.stroke))
    }

    private var sortedTitles: [SavedTitle] {
        library.titles.sorted { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
    }

    private func itemSummary(_ title: SavedTitle) -> String {
        let n = title.meta.items.count
        return title.meta.type == "series" ? "\(n) episode\(n == 1 ? "" : "s")" : (n == 1 ? "Movie" : "\(n) files")
    }

    private func measure() async {
        let folders = library.titles.map { ($0.id, $0.folder) }
        let root = library.root
        let (measured, free) = await Task.detached(priority: .utility) {
            var result: [String: Int64] = [:]
            for (id, folder) in folders { result[id] = Self.directorySize(folder) }
            return (result, Self.freeSpace(at: root))
        }.value
        sizes = measured
        freeSpace = free
        hasMeasured = true
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    nonisolated static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    nonisolated static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct StorageTitleRow: View {
    let name: String
    let summary: String
    let size: String
    let divider: Bool
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(Theme.Palette.stroke).frame(height: 1) }
            HStack(spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text(summary)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: Theme.Space.xs)
                Text(size)
                    .font(Theme.Font.headline.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .contentTransition(.numericText())
                    .animation(Theme.Motion.appear, value: size)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: SettingsMetrics.smallGlyph, weight: .bold))
                        .foregroundStyle(Theme.Palette.danger)
                        .frame(width: SettingsMetrics.smallButton, height: SettingsMetrics.smallButton)
                        .background(Theme.Palette.danger.opacity(hovering ? 0.2 : 0.1), in: Circle())
                }
                .buttonStyle(SettingsPressStyle())
                .help("Delete \(name)")
                .accessibilityLabel("Delete \(name)")
            }
            .padding(.vertical, Theme.Space.s)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete…", role: .destructive, action: onDelete)
        }
    }
}

private enum StorageMetrics {
    #if os(macOS)
    static let statSpacing: CGFloat = Theme.Space.s
    static let statPadding: CGFloat = Theme.Space.m
    static let statValueSize: CGFloat = 20
    #else
    static let statSpacing: CGFloat = Theme.Space.xs
    static let statPadding: CGFloat = Theme.Space.s
    static let statValueSize: CGFloat = 18
    #endif
}
