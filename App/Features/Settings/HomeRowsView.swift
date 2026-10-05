import SwiftUI

/// Show, hide and reorder Home rows. Presented as a sheet from Settings and from Home.
struct HomeRowsView: View {
    var onDone: (() -> Void)?
    @Environment(AddonRegistry.self) private var registry
    @Environment(AppSettings.self) private var settings

    private var rows: [CatalogRef] {
        settings.homeRows.arranged(registry.homeCatalogs.map(CatalogRef.init), id: \.homeRowID)
    }

    var body: some View {
        @Bindable var settings = settings
        let rows = rows
        let ids = rows.map(\.homeRowID)
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: "Home Rows", subtitle: subtitle(rows)) {
                HStack(spacing: Theme.Space.xs) {
                    Button(Self.resetTitle) {
                        withAnimation(SettingsMetrics.listSpring) { settings.homeRows = HomeRowPrefs() }
                    }
                    .buttonStyle(.ds(.ghost, compact: true))
                    .disabled(settings.homeRows.isDefault)
                    if let onDone {
                        Button("Done", action: onDone)
                            .buttonStyle(.ds(.primary, compact: true))
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.horizontal, SettingsMetrics.pageGutter)
            .padding(.top, SettingsMetrics.pageTop)
            .padding(.bottom, Theme.Space.s)

            List {
                Section {
                    pinnedRow("Continue Watching", detail: "Titles you started streaming",
                              isOn: $settings.homeRows.showsContinueWatching)
                    pinnedRow("Suggested for You", detail: "Picks based on your watch history, also shown at the top",
                              isOn: $settings.homeRows.showsSuggestions)
                    pinnedRow("Browse by Genre", detail: "Genre shortcuts",
                              isOn: $settings.homeRows.showsGenres)
                } header: {
                    sectionHeader("Pinned to the top")
                }

                Section {
                    if rows.isEmpty {
                        Text("No catalogs yet. Add a catalog addon such as Cinemeta in Addons.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .listRowBackground(Theme.Palette.surface)
                    }
                    ForEach(rows) { ref in
                        HomeRowItem(ref: ref, isOn: Binding(
                            get: { !settings.homeRows.isHidden(ref.homeRowID) },
                            set: { on in withAnimation(Theme.Motion.fast) { settings.homeRows.setHidden(ref.homeRowID, !on) } }
                        ))
                        .contextMenu { menu(for: ref, ids: ids) }
                        .listRowBackground(Theme.Palette.surface)
                        .listRowSeparatorTint(Theme.Palette.stroke)
                    }
                    .onMove { from, to in
                        settings.homeRows.move(fromOffsets: from, toOffset: to, in: ids)
                    }
                } header: {
                    sectionHeader("Catalogs")
                } footer: {
                    Text(footer)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.top, Theme.Space.xxs)
                }
            }
            .scrollContentBackground(.hidden)
            #if os(iOS)
            .listStyle(.insetGrouped)
            .environment(\.editMode, .constant(.active))
            #else
            .listStyle(.inset)
            .padding(.horizontal, SettingsMetrics.pageGutter - Theme.Space.m)
            #endif
        }
        .dsCanvas()
        .dsPageTitle("Home Rows")
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 620, minHeight: 560, idealHeight: 720)
        #endif
    }

    #if os(iOS)
    private static let resetTitle = "Reset"
    #else
    private static let resetTitle = "Reset to Default"
    #endif

    private func subtitle(_ rows: [CatalogRef]) -> String {
        let shown = rows.filter { !settings.homeRows.isHidden($0.homeRowID) }.count
        return rows.isEmpty ? "Choose what Home shows" : "\(shown) of \(rows.count) catalogs shown"
    }

    private var footer: String {
        #if os(iOS)
        "Drag to reorder. Catalogs from newly added addons appear at the end. Disabled addons aren't listed."
        #else
        "Drag rows to reorder, or right-click for more options. Catalogs from newly added addons appear at the end. Disabled addons aren't listed."
        #endif
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Theme.Font.caption.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(Theme.Palette.textTertiary)
    }

    private func pinnedRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer(minLength: Theme.Space.m)
            DSToggle(label: "Show \(title)", isOn: isOn)
        }
        .padding(.vertical, Theme.Space.xxs)
        .opacity(isOn.wrappedValue ? 1 : 0.55)
        .listRowBackground(Theme.Palette.surface)
        .listRowSeparatorTint(Theme.Palette.stroke)
    }

    @ViewBuilder
    private func menu(for ref: CatalogRef, ids: [HomeRowID]) -> some View {
        let id = ref.homeRowID
        let i = ids.firstIndex(of: id) ?? 0
        let hidden = settings.homeRows.isHidden(id)
        Button(hidden ? "Show on Home" : "Hide from Home") { settings.homeRows.setHidden(id, !hidden) }
        Divider()
        Button("Move to Top") { move(i, to: 0, ids) }.disabled(i == 0)
        Button("Move Up") { move(i, to: i - 1, ids) }.disabled(i == 0)
        Button("Move Down") { move(i, to: i + 2, ids) }.disabled(i >= ids.count - 1)
        Button("Move to Bottom") { move(i, to: ids.count, ids) }.disabled(i >= ids.count - 1)
    }

    private func move(_ index: Int, to offset: Int, _ ids: [HomeRowID]) {
        withAnimation(SettingsMetrics.listSpring) {
            settings.homeRows.move(fromOffsets: [index], toOffset: offset, in: ids)
        }
    }
}

private struct HomeRowItem: View {
    let ref: CatalogRef
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            #if os(macOS)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .accessibilityHidden(true)
            #endif
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.catalog.displayName)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text("\(DisplayFormat.typeLabel(ref.catalog.type)) · \(ref.addon.manifest.name)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.m)
            DSToggle(label: "Show \(ref.title)", isOn: $isOn)
        }
        .padding(.vertical, Theme.Space.xxs)
        .contentShape(Rectangle())
        .opacity(isOn ? 1 : 0.55)
    }
}
