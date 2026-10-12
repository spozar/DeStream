import SwiftUI

/// Library folder, downloads, playback, storage and about, as cards on the dark canvas. OWNER: UI Agent 1.
/// macOS: a sidebar section (Cmd-,). iOS: the Settings tab (Addons and Storage are pushed from here).
struct SettingsView: View {
    var body: some View {
        SettingsPage(title: "Settings", subtitle: "Library, downloads and playback") {
            StremioAccountCard()
            SuggestionsSettingsSection()
            #if os(iOS)
            SettingsCard(title: "Manage", systemImage: "slider.horizontal.3") {
                navRow("Addons", detail: "Catalogs and stream sources", icon: "puzzlepiece.extension.fill", divider: false) {
                    AddonSettingsView()
                }
                navRow("Storage", detail: "Saved titles and disk usage", icon: "internaldrive.fill", divider: true) {
                    StorageSettingsView()
                }
            }
            #endif
            HomeSettingsSection()
            LibrarySettingsSection()
            DownloadSettingsSection()
            PlaybackSettingsSection()
            #if os(macOS)
            StorageSettingsCard()
            #endif
            AboutSection()
        }
    }

    #if os(iOS)
    private func navRow<Destination: View>(_ title: String, detail: String, icon: String, divider: Bool,
                                           @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination()) {
            SettingsRow(title: title, detail: detail, divider: divider) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPressStyle())
    }
    #endif
}

struct HomeSettingsSection: View {
    @Environment(AddonRegistry.self) private var registry
    @Environment(AppSettings.self) private var settings
    @State private var editing = false

    var body: some View {
        SettingsCard(title: "Home", systemImage: "house.fill") {
            SettingsRow(title: "Home rows", detail: detail, divider: false) {
                Button("Customize…") { editing = true }
                    .buttonStyle(.ds(.secondary, compact: true))
            }
        }
        .sheet(isPresented: $editing) { HomeRowsView { editing = false } }
    }

    private var detail: String {
        let ids = registry.homeCatalogs.map { HomeRowID(addon: $0.addon, catalog: $0.catalog) }
        let shown = ids.filter { !settings.homeRows.isHidden($0) }.count
        return ids.isEmpty ? "Hide or reorder the catalog rows on Home" : "\(shown) of \(ids.count) catalog rows shown. Hide or reorder them."
    }
}

struct LibrarySettingsSection: View {
    @Environment(AppServices.self) private var services
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SettingsCard(title: "Library", systemImage: "folder.fill", footer: footer) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: library.isAvailable ? "externaldrive.fill" : "externaldrive.badge.exclamationmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(library.isAvailable ? Theme.Palette.textSecondary : Theme.Palette.warning)
                    Text(displayPath)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(SettingsMetrics.cardPadding - 4)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Theme.Palette.stroke))

                if !library.isAvailable {
                    StatusLine(kind: .warning, text: "The library folder is unavailable. Is the drive connected?")
                }
                #if os(macOS)
                HStack(spacing: Theme.Space.s) {
                    Button {
                        if let url = MacFileActions.chooseDirectory(startingAt: library.root) {
                            Task { await services.setLibraryRoot(url.path) }
                        }
                    } label: {
                        Label("Change Folder…", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.ds(.secondary, compact: true))
                    Button {
                        MacFileActions.reveal(library.root)
                    } label: {
                        Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.ds(.ghost, compact: true))
                    Spacer()
                    if settings.libraryPathOverride != nil {
                        Button("Reset to Default") { Task { await services.setLibraryRoot(nil) } }
                            .buttonStyle(.ds(.ghost, compact: true))
                    }
                }
                .padding(.top, Theme.Space.xxs)
                #endif
            }
        }
    }

    private var footer: String {
        #if os(iOS)
        "Saved titles are stored on this iPhone and excluded from iCloud backup. They are also visible in the Files app."
        #else
        "Each title gets its own folder with a meta.json, poster and video files."
        #endif
    }

    private var displayPath: String {
        let path = library.root.path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

struct DownloadSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsCard(title: "Downloads", systemImage: "arrow.down.circle.fill") {
            SettingsRow(title: "Simultaneous downloads", detail: "How many files download at the same time", divider: false) {
                DSStepper(value: $settings.maxConcurrentDownloads, range: 1...5, label: "Simultaneous downloads")
            }
            #if os(iOS)
            SettingsRow(title: "Wi‑Fi only", detail: "Pause downloads on cellular. Paused downloads keep the setting they started with.") {
                DSToggle(label: "Download on Wi‑Fi only", isOn: $settings.downloadOnWiFiOnly)
            }
            #endif
        }
    }
}

struct PlaybackSettingsSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsCard(title: "Playback", systemImage: "play.rectangle.fill") {
            SettingsRow(title: "Use mpv engine",
                        detail: "Recommended. Plays MKV, HEVC and embedded subtitles. When off, AVPlayer is used for MP4 and HLS streams.",
                        divider: false) {
                DSToggle(label: "Use mpv engine", isOn: $settings.preferMPV)
            }
        }
        SettingsCard(title: "Audio & Subtitles", systemImage: "captions.bubble.fill",
                     footer: "Applied when a video starts; you can still switch tracks in the player. Subtitles from addons such as OpenSubtitles are loaded in these languages (mpv engine only).") {
            SettingsRow(title: "Audio language", detail: "Used when the video has this language", divider: false) {
                DSMenuPicker(label: "Audio language", selection: $settings.audioLanguage,
                             options: [("", "Original")] + Self.languageOptions)
            }
            SettingsRow(title: "Subtitles", detail: modeDetail) {
                DSMenuPicker(label: "Subtitles", selection: $settings.subtitleMode,
                             options: SubtitleMode.allCases.map { ($0, $0.title) })
            }
            SettingsRow(title: "Subtitle language") {
                DSMenuPicker(label: "Subtitle language", selection: $settings.subtitleLanguage, options: Self.languageOptions)
            }
            SettingsRow(title: "Fallback language", detail: "When no subtitles exist in your first choice") {
                DSMenuPicker(label: "Fallback subtitle language", selection: $settings.subtitleFallbackLanguage,
                             options: [("", "None")] + Self.languageOptions.filter { $0.value != settings.subtitleLanguage })
            }
        }
        SubtitleStyleSection()
    }

    private var modeDetail: String {
        switch settings.subtitleMode {
        case .off: "Start without subtitles"
        case .foreignAudio: "Only when the audio isn't in your subtitle language; otherwise forced subtitles for foreign dialogue"
        case .always: "Always start with subtitles in your language"
        }
    }

    static let languageOptions: [(value: String, title: String)] = LanguageCodes.common
        .map { ($0, LanguageCodes.displayName($0)) }
        .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
}

struct AboutSection: View {
    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            BrandMark(height: 40)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Version \(Self.version)")
                    .font(Theme.Font.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text("Streams and saves titles through Stremio addons.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .dsCard(padding: SettingsMetrics.cardPadding)
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
