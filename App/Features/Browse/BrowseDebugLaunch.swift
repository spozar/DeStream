#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// DEBUG-only visual-check harness for Home / Search (macOS).
///
///     DeStream -DeStreamOpenBrowse home|search|rows|discover [-DeStreamBrowseQuery batman]
///
/// Opens an extra window backed by isolated services: Cinemeta only (nothing read from or written to the
/// Keychain), progress in a temp store seeded with sample "Latest" entries, and a temp download store.
@_cdecl("DeStreamBrowseDebugInstall")
func deStreamBrowseDebugInstall() {
    guard let mode = UserDefaults.standard.string(forKey: "DeStreamOpenBrowse") else { return }
    NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { BrowseDebugLaunch.open(mode) }
    }
}

@MainActor
enum BrowseDebugLaunch {
    private static var window: NSWindow?

    static func open(_ mode: String) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("destream-ui2-debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let progressURL = temp.appendingPathComponent("progress.json")
        try? FileManager.default.removeItem(at: progressURL)

        let settings = AppSettings()
        let registry = AddonRegistry(store: AddonStore(load: { nil }, save: { _ in }))
        let library = LibraryStore(root: LibraryLocation.root(override: settings.libraryPathOverride))
        let progress = ProgressStore(fileURL: progressURL)
        // Signed-out account under a key nothing else uses, so the user's real session is never touched.
        let account = StremioAccount(keychainKey: "stremio.auth.debug")
        let addonSync = AddonSync(account: account, registry: registry)
        let librarySync = LibrarySync(account: account, progress: progress)
        let sync = SyncCoordinator(account: account, addonSync: addonSync, librarySync: librarySync, network: NetworkMonitor())
        let downloads = DownloadManager(settings: settings, libraryRoot: { library.root }, onItemCompleted: {},
                                        storageDirectory: temp.appendingPathComponent("downloads"), sessionFactory: .foreground)
        // Cinemeta-only suggestions with their own cache and defaults (no TMDB key, no iCloud).
        let recommendations = Recommendations(
            history: { .init(libraryItems: Array(librarySync.items.values), progress: Array(progress.entries.values)) },
            tmdbAvailable: { false },
            makeTMDB: { nil },
            fetchMeta: { type, id in try await registry.meta(type: type, id: id) },
            fetchCatalog: Recommendations.cinemetaCatalogFetcher(registry: registry),
            cacheDirectory: temp.appendingPathComponent("suggestions", isDirectory: true),
            defaults: UserDefaults(suiteName: "destream-ui2-debug") ?? .standard)
        seedDemo(progress)
        Task {
            await registry.installDefaultsIfNeeded()
            await library.reload()
        }

        let root = NavigationStack {
            Group {
                switch mode {
                case "search": SearchView(initialQuery: UserDefaults.standard.string(forKey: "DeStreamBrowseQuery") ?? "")
                case "rows": RowsOnly()
                case "discover": DiscoverView(isRoot: true)
                default: HomeView()
                }
            }
            .routeDestinations()
        }
        .environment(settings)
        .environment(registry)
        .environment(library)
        .environment(progress)
        .environment(downloads)
        .environment(account)
        .environment(addonSync)
        .environment(librarySync)
        .environment(sync)
        .environment(recommendations)
        .environment(\.play, PlayAction { request in print("[BrowseDebug] play \(request.videoId)") })

        let w = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1320, height: 880),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "BrowseDebug"
        w.titlebarAppearsTransparent = true
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    private static func seedDemo(_ progress: ProgressStore) {
        let now = Date()
        let samples: [ProgressStore.Entry] = [
            .init(videoId: "tt0903747:2:4", metaID: "tt0903747", metaType: "series", title: "Breaking Bad",
                  posterURL: "https://images.metahub.space/poster/medium/tt0903747/img",
                  seconds: 1450, duration: 2820, updatedAt: now, season: 2, episode: 4, episodeTitle: "Down"),
            .init(videoId: "tt0111161", metaID: "tt0111161", metaType: "movie", title: "The Shawshank Redemption",
                  posterURL: "https://images.metahub.space/poster/medium/tt0111161/img",
                  seconds: 3100, duration: 8520, updatedAt: now.addingTimeInterval(-60)),
            .init(videoId: "tt1375666", metaID: "tt1375666", metaType: "movie", title: "Inception",
                  posterURL: "https://images.metahub.space/poster/medium/tt1375666/img",
                  seconds: 7200, duration: 8880, updatedAt: now.addingTimeInterval(-120)),
            .init(videoId: "tt0468569", metaID: "tt0468569", metaType: "movie", title: "The Dark Knight",
                  posterURL: "https://images.metahub.space/poster/medium/tt0468569/img",
                  seconds: 600, duration: 9120, updatedAt: now.addingTimeInterval(-180)),
        ]
        samples.forEach(progress.save)
    }
}
/// Catalog rows without the billboard, to check rows below the fold.
private struct RowsOnly: View {
    @Environment(AddonRegistry.self) private var registry
    @State private var home = HomeModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.xl) {
                ForEach(home.rows) { CatalogRowView(model: $0) }
            }
            .padding(.vertical, Theme.Space.l)
        }
        .dsCanvas()
        .onChange(of: registry.homeCatalogs.map(CatalogRef.init).map(\.id), initial: true) {
            home.sync(registry.homeCatalogs.map(CatalogRef.init))
        }
    }
}
#endif
