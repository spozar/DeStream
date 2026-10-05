#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// DEBUG-only visual-check harness for the Detail page (macOS).
///
///     DeStream -DeStreamOpenDetail tt0903747:series [-DeStreamOpenEpisode tt0903747:1:3] [-DeStreamDemoProgress YES]
///
/// Opens an extra window with DetailView backed by isolated services: the addon list is read from the Keychain
/// but never written, progress lives in a temp copy of progress.json, and downloads use a temp store.
@_cdecl("DeStreamDetailDebugInstall")
func deStreamDetailDebugInstall() {
    guard let spec = UserDefaults.standard.string(forKey: "DeStreamOpenDetail") else { return }
    NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { DetailDebugLaunch.open(spec) }
    }
}

@MainActor
enum DetailDebugLaunch {
    private static var window: NSWindow?

    static func open(_ spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return }
        let id = parts.dropLast().joined(separator: ":"), type = parts[parts.count - 1]

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("destream-ui3-debug", isDirectory: true)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let progressURL = temp.appendingPathComponent("progress.json")
        try? FileManager.default.removeItem(at: progressURL)
        try? FileManager.default.copyItem(at: ProgressStore.defaultFileURL, to: progressURL)

        let settings = AppSettings()
        let registry = AddonRegistry(store: AddonStore(load: { try Keychain.read("addons") }, save: { _ in }))
        let library = LibraryStore(root: LibraryLocation.root(override: settings.libraryPathOverride))
        let progress = ProgressStore(fileURL: progressURL)
        // Signed-out account under a key nothing else uses, so the user's real session is never touched.
        let account = StremioAccount(keychainKey: "stremio.auth.debug")
        let addonSync = AddonSync(account: account, registry: registry)
        let librarySync = LibrarySync(account: account, progress: progress)
        let sync = SyncCoordinator(account: account, addonSync: addonSync, librarySync: librarySync, network: NetworkMonitor())
        let downloads = DownloadManager(settings: settings, libraryRoot: { library.root }, onItemCompleted: {},
                                        storageDirectory: temp.appendingPathComponent("downloads"), sessionFactory: .foreground)
        if UserDefaults.standard.bool(forKey: "DeStreamDemoProgress") { seedDemo(progress, metaID: id, type: type) }
        Task { await library.reload() }

        let root = NavigationStack {
            DetailView(preview: MetaPreview(id: id, type: type, name: id))
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
        .environment(\.play, PlayAction { request in
            FileHandle.standardError.write(Data(("[DetailDebug] play \(request.videoId) start=\(request.startAt.map { "\($0)" } ?? "nil") bg=\(request.backgroundURL ?? "nil") sub=\(request.subtitle ?? "nil")" + "\n").utf8))
        })

        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1240, height: 860),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "DetailDebug"
        w.titlebarAppearsTransparent = true
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    /// Fake progress in the temp store only: movie 60% watched; series S01E01–02 watched, S01E03 at 40%.
    private static func seedDemo(_ progress: ProgressStore, metaID: String, type: String) {
        let base = ProgressStore.Entry(videoId: metaID, metaID: metaID, metaType: type, title: metaID,
                                       seconds: 0, duration: nil, updatedAt: .now)
        if type == "movie" {
            var e = base; e.seconds = 0.6 * 7200; e.duration = 7200
            progress.save(e)
        } else {
            for ep in 1...2 {
                progress.markWatched(videoId: "\(metaID):1:\(ep)", metaID: metaID, metaType: type, title: metaID, duration: 2900)
            }
            var e = base; e.videoId = "\(metaID):1:3"; e.seconds = 0.4 * 2900; e.duration = 2900; e.updatedAt = .now.addingTimeInterval(5)
            progress.save(e)
        }
    }
}
#endif
