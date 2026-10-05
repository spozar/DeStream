import SwiftUI

/// macOS: custom blurred sidebar + NavigationStack detail. iOS: TabView with a NavigationStack per tab. OWNER: UI Agent 1 (Shell).
struct RootView: View {
    @Environment(AppServices.self) private var services
    @Environment(NetworkMonitor.self) private var network
    @Environment(StremioAccount.self) private var account

    var body: some View {
        content
            .environment(\.play, playAction)
            #if DEBUG
            // Screenshot/QA hook: launch with `-DSSection addons` to open a section directly.
            .task {
                if let raw = UserDefaults.standard.string(forKey: "DSSection"), let section = AppSection(rawValue: raw) {
                    services.selection = section
                }
            }
            #endif
            .onChange(of: network.isOnline, initial: true) { _, online in
                if !online, services.selection.requiresNetwork { services.selection = .saved }
            }
            .onChange(of: account.isSignedIn) { _, signedIn in
                if !signedIn, services.selection.requiresAccount { services.selection = .home }
            }
            #if os(iOS)
            .fullScreenCover(item: $playing) { request in
                PlayerView(request: request)
                    .environment(services)
                    .environment(services.settings)
                    .environment(services.library)
                    .environment(services.progress)
                    .environment(services.registry)
                    .environment(services.downloads)
                    .environment(services.network)
                    .environment(services.account)
                    .environment(services.librarySync)
                    .environment(services.sync)
            }
            #endif
    }

    /// Last started stream, so a double-click or repeated tap from any screen doesn't open the player twice.
    @State private var lastPlay: (key: String, at: Date)?

    private func isRepeat(_ request: PlaybackRequest) -> Bool {
        let key = request.videoId + "|" + request.url.absoluteString
        defer { lastPlay = (key, .now) }
        guard let lastPlay else { return false }
        return lastPlay.key == key && Date.now.timeIntervalSince(lastPlay.at) < 1.5
    }

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow

    private var playAction: PlayAction {
        PlayAction { request in
            guard !isRepeat(request) else { return }
            openWindow(id: "player", value: request)
        }
    }

    private var content: some View { MacRootView() }
    #else
    @State private var playing: PlaybackRequest?

    private var playAction: PlayAction {
        PlayAction { request in
            guard playing == nil, !isRepeat(request) else { return }
            PlayerAudioSession.activate()
            // Rotate first: mpv's video layer doesn't follow a rotation that happens mid-playback.
            PlayerPlatform.setPlayerPresented(true)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                playing = request
            }
        }
    }

    private var content: some View { PhoneRootView() }
    #endif
}

// MARK: - Shared pieces

extension Notification.Name {
    /// Posted (object: the `AppSection`) when the section that's already showing is picked again from the
    /// sidebar, tab bar or Go menu: its stack pops to the root, and Search focuses its field.
    static let reselectSection = Notification.Name("DeStream.reselectSection")
}

extension AppServices {
    /// Selects `section`, or re-selects it (see `Notification.Name.reselectSection`) when it's already showing.
    func select(_ section: AppSection) {
        if selection == section {
            NotificationCenter.default.post(name: .reselectSection, object: section)
        } else {
            selection = section
        }
    }
}

extension AppSection {
    var title: String {
        switch self {
        case .home: "Home"
        case .suggestions: "For You"
        case .discover: "Browse"
        case .search: "Search"
        case .library: "Library"
        case .saved: "Saved"
        case .downloads: "Downloads"
        case .addons: "Addons"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .suggestions: "sparkles"
        case .discover: "square.grid.2x2"
        case .search: "magnifyingglass"
        case .library: "books.vertical"
        case .saved: "rectangle.stack"
        case .downloads: "arrow.down.circle"
        case .addons: "puzzlepiece.extension"
        case .settings: "gearshape"
        }
    }

    /// Filled variant for the selected sidebar row / tab.
    var selectedSystemImage: String {
        switch self {
        case .home: "house.fill"
        case .suggestions: "sparkles"
        case .discover: "square.grid.2x2.fill"
        case .search: "magnifyingglass"
        case .library: "books.vertical.fill"
        case .saved: "rectangle.stack.fill"
        case .downloads: "arrow.down.circle.fill"
        case .addons: "puzzlepiece.extension.fill"
        case .settings: "gearshape.fill"
        }
    }
}

/// The root view of one section, without its NavigationStack.
struct SectionContent: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .home: HomeView()
        case .suggestions: RecommendationsView()
        case .discover: DiscoverView(isRoot: true)
        case .search: SearchView()
        case .library: StremioLibraryView()
        case .saved: SavedView()
        case .downloads: DownloadsView()
        case .addons: AddonSettingsView()
        case .settings: SettingsView()
        }
    }
}

/// Floating "offline" pill shown at the top of the content area.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 22, height: 22)
                .background(Theme.Palette.warning, in: Circle())
            Text("You're offline")
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("Showing saved titles")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.leading, 6)
        .padding(.trailing, Theme.Space.m)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: Theme.Radius.pill)
        .overlay(Capsule().strokeBorder(Theme.Palette.warning.opacity(0.35)))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
        .padding(.top, Theme.Space.s)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// The app's nested-"D" logo mark (same artwork as the app icon).
struct BrandMark: View {
    var height: CGFloat = 44

    var body: some View {
        Image("BrandMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: height)
            .accessibilityLabel("DeStream")
    }
}

// MARK: - macOS

#if os(macOS)
private struct MacRootView: View {
    @Environment(AppServices.self) private var services
    @Environment(NetworkMonitor.self) private var network
    @State private var path = NavigationPath()

    var body: some View {
        HStack(spacing: 0) {
            MacSidebar()
                .frame(width: Theme.Layout.sidebarWidth)
            detail
        }
        .background(Theme.Palette.canvas)
        .ignoresSafeArea()
        .onChange(of: services.selection) { path = NavigationPath() }
        .onReceive(NotificationCenter.default.publisher(for: .reselectSection)) { note in
            if note.object as? AppSection == services.selection { path = NavigationPath() }
        }
        #if DEBUG
        // QA hook: `-DSOpenSaved YES` pushes the first saved title (screenshots of pushed pages).
        .onChange(of: services.library.titles.first?.id) { _, id in
            if let id, path.isEmpty, UserDefaults.standard.bool(forKey: "DSOpenSaved") {
                path.append(Route.saved(titleID: id))
            }
        }
        #endif
        .frame(minWidth: 900, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    private var detail: some View {
        NavigationStack(path: $path) {
            Group {
                if network.hasResolved {
                    SectionContent(section: services.selection)
                } else {
                    Color.clear
                }
            }
            .id(DetailIdentity(section: services.selection, reload: services.reloadToken))
            .routeDestinations()
        }
        .dsCanvas()
        .overlay(alignment: .topLeading) {
            if !path.isEmpty {
                IconCircleButton("chevron.left", label: "Back", size: 36) { path.removeLast() }
                    .keyboardShortcut("[", modifiers: .command)
                    .padding(.top, Theme.Space.m)
                    .padding(.leading, Theme.Space.l)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .overlay(alignment: .top) {
            if !network.isOnline { OfflineBanner().allowsHitTesting(false) }
        }
        .animation(Theme.Motion.appear, value: path.isEmpty)
        .animation(Theme.Motion.appear, value: network.isOnline)
    }
}

/// Custom sidebar: blurred dark panel, wordmark, accent-pill selection. Bound directly to `services.selection`.
private struct MacSidebar: View {
    @Environment(AppServices.self) private var services
    @Environment(NetworkMonitor.self) private var network
    @Environment(StremioAccount.self) private var account

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandMark(height: 48)
                .padding(.horizontal, Theme.Space.l)
                .padding(.top, 52)
                .padding(.bottom, Theme.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WindowDragArea())

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if network.isOnline {
                        group("Discover", account.isSignedIn ? [.home, .suggestions, .discover, .search, .library] : [.home, .suggestions, .discover, .search])
                    }
                    group("Offline", [.saved, .downloads])
                }
                .padding(.horizontal, Theme.Space.s)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Rectangle().fill(Theme.Palette.stroke).frame(height: 1)
                    .padding(.horizontal, Theme.Space.xs)
                    .padding(.bottom, Theme.Space.s)
                SidebarRow(section: .addons, badge: 0)
                SidebarRow(section: .settings, badge: 0)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.l)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                VisualEffectBackground()
                Theme.Palette.chrome.opacity(0.72)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Palette.stroke).frame(width: 1).ignoresSafeArea()
        }
        .animation(Theme.Motion.appear, value: network.isOnline)
        .animation(Theme.Motion.appear, value: account.isSignedIn)
    }

    private func group(_ title: String, _ sections: [AppSection]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(Theme.Font.micro)
                .tracking(1.2)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, Theme.Space.s)
                .padding(.bottom, Theme.Space.xs)
            ForEach(sections) { section in
                SidebarRow(section: section, badge: section == .downloads ? services.activeDownloadCount : 0)
            }
        }
    }
}

private struct SidebarRow: View {
    let section: AppSection
    let badge: Int
    @Environment(AppServices.self) private var services

    var body: some View {
        SidebarButton(title: section.title, systemImage: section.systemImage, selectedSystemImage: section.selectedSystemImage,
                      selected: services.selection == section, badge: badge) {
            services.select(section)
        }
    }
}

private struct SidebarButton: View {
    let title: String
    let systemImage: String
    let selectedSystemImage: String
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: selected ? selectedSystemImage : systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 22)
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.Palette.accentHover) : AnyShapeStyle(Theme.Palette.textSecondary))
                Text(title)
                    .font(.system(size: 14, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected || hovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 11, weight: .heavy).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(Theme.Palette.accent, in: Capsule())
                        .accessibilityLabel("\(badge) active")
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .fill(selected ? Theme.Palette.accentSoft : Color.white.opacity(hovering ? 0.06 : 0))
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Theme.Palette.accentGradient)
                        .frame(width: 3, height: 18)
                        .offset(x: -1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.fast, value: hovering)
        .animation(Theme.Motion.hover, value: selected)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Behind-window blur for the sidebar.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Lets the user drag the (title-bar-less) window from a non-interactive area.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct DetailIdentity: Hashable {
    var section: AppSection
    var reload: Int
}
#endif

// MARK: - iOS

#if os(iOS)
private struct PhoneRootView: View {
    @Environment(AppServices.self) private var services
    @Environment(NetworkMonitor.self) private var network
    @Environment(StremioAccount.self) private var account
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// iPhone online: four tabs plus Search fit without UIKit's "More" overflow, so Library, Saved, Downloads
    /// and Settings share one "Library" hub tab (tagged `.saved`). iPad keeps every section in the adaptable sidebar.
    private var usesHub: Bool { sizeClass == .compact && network.isOnline }

    private func tabValue(for section: AppSection) -> AppSection {
        usesHub && PhoneLibraryHub.sections.contains(section) ? .saved : section
    }

    private var selection: Binding<AppSection> {
        Binding {
            tabValue(for: services.selection)
        } set: { section in
            if section == tabValue(for: services.selection) {
                NotificationCenter.default.post(name: .reselectSection, object: section)
            } else {
                services.selection = section
            }
        }
    }

    var body: some View {
        TabView(selection: selection) {
            if usesHub {
                tab(.home)
                tab(.suggestions)
                tab(.discover)
                Tab("Library", systemImage: "books.vertical.fill", value: AppSection.saved) {
                    stack(.saved, isHub: true)
                }
                .badge(services.activeDownloadCount)
                tab(.search, role: .search)
            } else {
                if network.isOnline {
                    tab(.home)
                    tab(.suggestions)
                    tab(.discover)
                    if account.isSignedIn { tab(.library) }
                    tab(.search, role: .search)
                }
                TabSection("Offline") {
                    tab(.saved)
                    tab(.downloads)
                        .badge(services.activeDownloadCount)
                }
                tab(.settings)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(Theme.Palette.accent)
        .dsSelectionHaptic(services.selection)
        .preferredColorScheme(.dark)
    }

    private func tab(_ section: AppSection, role: TabRole? = nil) -> some TabContent<AppSection> {
        Tab(section.title, systemImage: section.selectedSystemImage, value: section, role: role) {
            stack(section, isHub: false)
        }
    }

    private func stack(_ section: AppSection, isHub: Bool) -> some View {
        TabStack(section: section, isHub: isHub)
            .toolbarBackground(.ultraThinMaterial, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarColorScheme(.dark, for: .tabBar)
    }
}

/// iPhone "Library" tab: your Stremio library, saved titles, downloads and settings, one tap away.
private struct PhoneLibraryHub: View {
    static let sections: Set<AppSection> = [.library, .saved, .downloads, .addons, .settings]

    @Environment(AppServices.self) private var services
    @Environment(StremioAccount.self) private var account
    @Environment(LibraryStore.self) private var library

    var body: some View {
        SettingsPage(title: "Library", subtitle: "Your titles, downloads and settings") {
            SettingsCard(title: "Your Titles", systemImage: "books.vertical.fill") {
                if account.isSignedIn {
                    row(.library, title: "Stremio Library", detail: "Your synced library and watch history", divider: false)
                }
                row(.saved, detail: savedDetail, divider: account.isSignedIn)
                row(.downloads, detail: downloadsDetail, divider: true, badge: services.activeDownloadCount)
            }
            SettingsCard(title: "App", systemImage: "gearshape.fill") {
                row(.settings, detail: "Account, suggestions, playback and storage", divider: false)
            }
        }
    }

    private var savedDetail: String {
        let count = library.titles.count
        return count == 0 ? "Titles kept on this device" : "\(count) \(count == 1 ? "title" : "titles") on this device"
    }

    private var downloadsDetail: String {
        let active = services.activeDownloadCount
        return active == 0 ? "Transfers and finished files" : "\(active) in progress"
    }

    private func row(_ section: AppSection, title: String? = nil, detail: String, divider: Bool, badge: Int = 0) -> some View {
        let title = title ?? section.title
        return NavigationLink(value: Route.section(section)) {
            SettingsRow(title: title, detail: detail, divider: divider) {
                HStack(spacing: Theme.Space.xs) {
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 12, weight: .heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(minWidth: 22, minHeight: 20)
                            .background(Theme.Palette.accent, in: Capsule())
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowPressStyle())
        .accessibilityLabel(badge > 0 ? "\(title), \(badge) active" : title)
        .accessibilityHint(detail)
    }
}

private struct TabStack: View {
    let section: AppSection
    var isHub = false
    @Environment(AppServices.self) private var services
    @Environment(NetworkMonitor.self) private var network
    @State private var path = NavigationPath()

    private var showsOfflineBanner: Bool {
        !network.isOnline && (section == .saved || section == .downloads)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if isHub { PhoneLibraryHub() } else { SectionContent(section: section) }
            }
            .id(services.reloadToken)
            .routeDestinations()
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .dsCanvas()
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsOfflineBanner {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.Motion.content, value: showsOfflineBanner)
        .onReceive(NotificationCenter.default.publisher(for: .reselectSection)) { note in
            guard note.object as? AppSection == section, !path.isEmpty else { return }
            path.removeLast(path.count)
        }
    }
}
#endif

extension View {
    /// Registers destinations for every `Route`.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            Group {
                switch route {
                case .detail(let preview): DetailView(preview: preview)
                case .saved(let id): SavedDetailView(titleID: id)
                case .discover(let seed): DiscoverView(seed: seed)
                case .section(let section): SectionContent(section: section)
                case .watchHistory: WatchHistoryView()
                }
            }
            #if os(macOS)
            // The shell draws its own floating back button over the artwork.
            .navigationBarBackButtonHidden(true)
            #endif
        }
    }
}
