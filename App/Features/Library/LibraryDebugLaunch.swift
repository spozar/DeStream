#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// DEBUG-only visual-check harness for Downloads / Saved (macOS).
///
///     DeStream -DeStreamOpenLibrary downloads|downloads-empty|saved|saved:<titleID> [-DeStreamLibraryDemo YES]
///
/// Opens an extra window backed by the real library folder (read-only unless you click delete), a temp copy of
/// progress.json, and a temp download store (the demo flag adds fake active/paused/failed items that never start).
@_cdecl("DeStreamLibraryDebugInstall")
func deStreamLibraryDebugInstall() {
    guard let spec = UserDefaults.standard.string(forKey: "DeStreamOpenLibrary") else { return }
    NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { LibraryDebugLaunch.open(spec) }
    }
}

@MainActor
enum LibraryDebugLaunch {
    private static var window: NSWindow?
    private static var services: AppServices?

    static func open(_ spec: String) {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("destream-ui5-debug", isDirectory: true)
        try? fm.removeItem(at: temp)
        try? fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let progressURL = temp.appendingPathComponent("progress.json")
        try? fm.copyItem(at: ProgressStore.defaultFileURL, to: progressURL)

        let downloadsDir = temp.appendingPathComponent("downloads", isDirectory: true)
        let realStore = DownloadStore(directory: DownloadStore.defaultDirectory)
        var items = spec == "downloads-empty" ? [] : realStore.loadItems().filter { $0.state == .completed }
        if UserDefaults.standard.bool(forKey: "DeStreamLibraryDemo") { items += demoItems(basedOn: items.first) }
        try? fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
        try? DownloadStore(directory: downloadsDir).saveItems(items)

        let services = AppServices()
        self.services = services
        let settings = services.settings
        let library = LibraryStore(root: LibraryLocation.root(override: settings.libraryPathOverride))
        let progress = ProgressStore(fileURL: progressURL)
        let downloads = DownloadManager(settings: settings, libraryRoot: { library.root }, onItemCompleted: {},
                                        storageDirectory: downloadsDir, sessionFactory: .foreground)
        Task { await library.reload() }

        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let root = NavigationStack {
            Group {
                if parts.first == "saved", parts.count == 2 {
                    SavedDetailView(titleID: parts[1])
                } else if parts.first == "saved" {
                    SavedView()
                } else {
                    DownloadsView()
                }
            }
            .routeDestinations()
        }
        .environment(services)
        .environment(services.network)
        .environment(services.account)
        .environment(services.addonSync)
        .environment(services.librarySync)
        .environment(services.sync)
        .environment(settings)
        .environment(library)
        .environment(progress)
        .environment(downloads)
        .environment(\.play, PlayAction { request in
            print("[LibraryDebug] play \(request.videoId) start=\(request.startAt.map { "\($0)" } ?? "nil") local=\(request.isLocal)")
        })
        .preferredColorScheme(.dark)

        let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1240, height: 860),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "LibraryDebug"
        w.titlebarAppearsTransparent = true
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    private static func demoItems(basedOn real: DownloadItem?) -> [DownloadItem] {
        let gb: Int64 = 1_000_000_000
        func item(_ metaID: String, _ name: String, season: Int?, episode: Int?, epTitle: String?, state: DownloadItem.State,
                  written: Int64, expected: Int64, error: String? = nil) -> DownloadItem {
            DownloadItem(id: UUID(), metaID: metaID, metaType: season == nil ? "movie" : "series", titleName: name,
                         videoId: "\(metaID):\(season ?? 0):\(episode ?? 0)", season: season, episode: episode, episodeTitle: epTitle,
                         streamURL: "about:blank", addonName: "Torrentio", filename: nil, state: state,
                         bytesWritten: written, bytesExpected: expected, errorMessage: error, createdAt: .now,
                         filenameHint: "Show.S01E02.2160p.WEB-DL.HDR.mkv")
        }
        let metaID = real?.metaID ?? "tt0000001"
        let name = real?.titleName ?? "Lanterns"
        return [
            item(metaID, name, season: 1, episode: 2, epTitle: "The Long Night", state: .downloading, written: 46 * gb / 10, expected: 85 * gb / 10),
            item("tt9999998", "The Quiet Harbor", season: nil, episode: nil, epTitle: nil, state: .paused, written: 12 * gb / 10, expected: 41 * gb / 10),
            item("tt9999999", "Northern Lights", season: 2, episode: 5, epTitle: "Aurora", state: .failed, written: 0, expected: 0,
                 error: "The server returned HTTP 403. The debrid link may have expired — try another stream from the same addon."),
        ]
    }
}
#endif
