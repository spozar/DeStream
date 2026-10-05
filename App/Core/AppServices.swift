import Foundation
import Observation

/// Top-level navigation destinations (macOS sidebar items / iOS tabs).
enum AppSection: String, Hashable, CaseIterable, Sendable, Identifiable {
    case home, suggestions, discover, search, library, saved, downloads, addons, settings
    var id: String { rawValue }

    /// Sections that need the network to be useful.
    var requiresNetwork: Bool { self == .home || self == .suggestions || self == .discover || self == .search || self == .library }

    /// Sections that only exist while signed in to a Stremio account.
    var requiresAccount: Bool { self == .library }
}

/// Root dependency container injected into the SwiftUI environment. OWNER: Agent 6 (Shell).
@MainActor @Observable
final class AppServices {
    let settings: AppSettings
    let registry: AddonRegistry
    let library: LibraryStore
    let progress: ProgressStore
    let downloads: DownloadManager
    let network: NetworkMonitor
    let account: StremioAccount
    let addonSync: AddonSync
    let librarySync: LibrarySync
    let sync: SyncCoordinator
    let tmdb: TMDBKeyStore
    let recommendations: Recommendations

    /// Current sidebar/tab selection, shared with menu commands.
    var selection: AppSection = .home
    /// Bumped by "Reload" (Cmd-R); the shell rebuilds the visible section when it changes.
    private(set) var reloadToken = 0
    private var started = false

    init() {
        let settings = AppSettings()
        self.settings = settings
        let registry = AddonRegistry()
        self.registry = registry
        let library = LibraryStore(root: LibraryLocation.root(override: settings.libraryPathOverride))
        self.library = library
        let progress = ProgressStore()
        self.progress = progress
        let network = NetworkMonitor()
        self.network = network
        downloads = DownloadManager(
            settings: settings,
            libraryRoot: { library.root },
            onItemCompleted: { Task { await library.reload() } }
        )
        let account = StremioAccount()
        self.account = account
        addonSync = AddonSync(account: account, registry: registry)
        librarySync = LibrarySync(account: account, progress: progress)
        let sync = SyncCoordinator(account: account, addonSync: addonSync, librarySync: librarySync, network: network)
        self.sync = sync
        let tmdb = TMDBKeyStore()
        self.tmdb = tmdb
        recommendations = Recommendations(librarySync: librarySync, progress: progress, registry: registry, tmdb: tmdb)
        registry.onChange = { [weak sync] in sync?.scheduleSync() }
        librarySync.onLocalChange = { [weak sync] in sync?.scheduleSync() }
        sync.onSignedOut = { [librarySync] in librarySync.reset() }
    }

    /// Runs once per launch; the macOS main window re-running its `.task` after being reopened is a no-op.
    func start() async {
        guard !started else { return }
        started = true
        downloads.restore()
        await library.reload()
        await downloads.pruneMissingFiles()
        library.startWatching()
        await registry.refreshManifests()
        sync.start()
    }

    func reload() {
        reloadToken += 1
        Task {
            await library.reload()
            await downloads.pruneMissingFiles()
            if network.isOnline { await registry.refreshManifests() }
        }
    }

    /// Points the library at a new root (nil = platform default) and rescans it.
    func setLibraryRoot(_ path: String?) async {
        settings.libraryPathOverride = path
        await library.setRoot(LibraryLocation.root(override: path))
    }

    /// Called when the app moves to the background or is about to quit.
    func flush() async {
        await library.flushProgress()
        await sync.sceneDidEnterBackground()
    }

    var activeDownloadCount: Int {
        downloads.items.filter { [.queued, .downloading, .waiting].contains($0.state) }.count
    }
}
