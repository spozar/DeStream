import Foundation
import Observation

/// Queue of downloads persisted across restarts. Delegate-based URLSession (background on iOS).
/// The only component that writes video files into the library. OWNER: Agent 4 (Downloads).
@MainActor @Observable
final class DownloadManager {
    private(set) var items: [DownloadItem] = []
    /// Transfer rate per active item, for speed/ETA display.
    private(set) var rates: [UUID: TransferRateEstimator] = [:]

    /// Set by the iOS AppDelegate in `handleEventsForBackgroundURLSession`; called once the session has delivered all events.
    static var backgroundCompletionHandler: (() -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let libraryRoot: @MainActor () -> URL
    @ObservationIgnored private let onItemCompleted: @MainActor () -> Void
    @ObservationIgnored let store: DownloadStore
    @ObservationIgnored private let factory: DownloadSessionFactory
    @ObservationIgnored private let allowsFileURLs: Bool
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var tasks: [UUID: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var validated: Set<UUID> = []
    @ObservationIgnored private var startedFromResumeData: Set<UUID> = []
    @ObservationIgnored private var freshRetried: Set<UUID> = []
    @ObservationIgnored private var finishing: Set<UUID> = []
    /// Paused tasks whose resume data hasn't been delivered yet; restarting them early would lose the partial file.
    @ObservationIgnored private var awaitingResumeData: Set<UUID> = []
    @ObservationIgnored private var prepareTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var installTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastPersist = Date.distantPast
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    convenience init(settings: AppSettings, libraryRoot: @escaping @MainActor () -> URL, onItemCompleted: @escaping @MainActor () -> Void) {
        self.init(settings: settings, libraryRoot: libraryRoot, onItemCompleted: onItemCompleted,
                  storageDirectory: DownloadStore.defaultDirectory, sessionFactory: .platformDefault)
    }

    /// `allowsFileURLs` is for tests only (downloads from file:// fixtures).
    init(settings: AppSettings, libraryRoot: @escaping @MainActor () -> URL, onItemCompleted: @escaping @MainActor () -> Void,
         storageDirectory: URL, sessionFactory: DownloadSessionFactory, allowsFileURLs: Bool = false) {
        self.settings = settings
        self.libraryRoot = libraryRoot
        self.onItemCompleted = onItemCompleted
        self.store = DownloadStore(directory: storageDirectory)
        self.factory = sessionFactory
        self.allowsFileURLs = allowsFileURLs
        // Loaded eagerly so events from a background relaunch find their items even before restore() runs.
        self.items = store.loadItems()

        let delegate = DownloadSessionDelegate(stagingDirectory: store.stagingDirectory) { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
        // A request can only narrow the session's cellular policy, so the session allows it and each request
        // applies "Wi-Fi only"; toggling the setting then takes effect without recreating the (background) session.
        session = URLSession(configuration: sessionFactory.makeConfiguration(true), delegate: delegate, delegateQueue: nil)

        if let name = sessionFactory.terminationNotification {
            terminationObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.prepareForTermination() }
            }
        }
        observeSettings()
    }

    /// Ends the URLSession; only needed by tests that create several managers.
    func invalidate() {
        session.invalidateAndCancel()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
    }

    // MARK: - Public API

    func enqueue(meta: MetaDetail, video: Video?, stream: AddonStream) {
        let videoId = video?.id ?? meta.id
        if items.contains(where: { $0.videoId == videoId && [.queued, .downloading, .waiting, .paused].contains($0.state) }) { return }
        for old in items where old.videoId == videoId {
            store.deleteResumeData(for: old.id)
            deleteStagedFile(of: old)
            forget(old.id)
        }
        items.removeAll { $0.videoId == videoId }

        var item = DownloadItem(
            id: UUID(), metaID: meta.id, metaType: meta.type, titleName: meta.name, videoId: videoId,
            season: video?.season, episode: video?.episode, episodeTitle: video?.displayTitle,
            streamURL: stream.stream.url ?? "", addonName: stream.addonName, filename: nil, state: .queued,
            bytesWritten: 0, bytesExpected: stream.stream.behaviorHints?.videoSize ?? 0, errorMessage: nil,
            createdAt: Date(), filenameHint: stream.stream.behaviorHints?.filename
        )
        if downloadURL(for: item) == nil {
            item.state = .failed
            item.errorMessage = "This stream has no downloadable http(s) URL."
        }
        items.append(item)

        let root = libraryRoot()
        chainTitleWork(meta.id) { _ = try? await LibraryWriter.prepareTitle(meta, root: root) }
        persist()
        schedule()
    }

    func pause(_ id: UUID) {
        guard let i = index(id) else { return }
        switch items[i].state {
        case .queued:
            items[i].state = .paused
        case .downloading, .waiting:
            guard !finishing.contains(id) else { return }
            items[i].state = .paused
            rates[id] = nil
            if let task = tasks.removeValue(forKey: id) { cancelKeepingResumeData(id, task) }
        default:
            return
        }
        persist()
        schedule()
    }

    /// Resumes a paused item or retries a failed one (from resume data when available).
    func resume(_ id: UUID) {
        guard let i = index(id), [.paused, .failed].contains(items[i].state) else { return }
        items[i].state = .queued
        items[i].errorMessage = nil
        items[i].failure = nil
        freshRetried.remove(id)
        persist()
        schedule()
    }

    func retry(_ id: UUID) { resume(id) }

    /// Stops the download and drops it from the queue, discarding partial data.
    func cancel(_ id: UUID) {
        guard let i = index(id), items[i].state != .completed, !finishing.contains(id) else { return }
        let item = items[i]
        discard(id)
        persist()
        schedule()
        removeTitleFolderIfUnused(metaID: item.metaID)
    }

    /// Removes the entry from the list. Never touches files already in the library.
    func remove(_ id: UUID) {
        guard let i = index(id), !finishing.contains(id) else { return }
        if items[i].state != .completed && items[i].state != .failed {
            cancel(id)
            return
        }
        let item = items[i]
        discard(id)
        persist()
        if item.state != .completed { removeTitleFolderIfUnused(metaID: item.metaID) }
    }

    func removeAllFinished() {
        for item in items where item.state == .completed { remove(item.id) }
    }

    /// Downloads of a title that haven't finished yet (what deleting the title would cancel).
    func inProgressCount(forTitle metaID: String) -> Int {
        items.filter { $0.metaID == metaID && [.queued, .downloading, .waiting, .paused].contains($0.state) }.count
    }

    /// Call before deleting a title: drops every unfinished download of it and waits until nothing
    /// is still writing into its folder (artwork preparation, a file being moved in).
    func cancelDownloads(forTitle metaID: String) async {
        let unfinished = { self.items.filter { $0.metaID == metaID && $0.state != .completed && !self.finishing.contains($0.id) } }
        for item in unfinished() { discard(item.id) }
        let installs = items.filter { $0.metaID == metaID }.compactMap { installTasks[$0.id] }
        for install in installs { await install.value }
        for item in unfinished() { discard(item.id) }
        persist()
        schedule()
        await prepareTasks[metaID]?.value
    }

    /// Drops completed entries after their files were deleted in the app (`videoId` nil = the whole title).
    func forgetCompleted(metaID: String, videoId: String? = nil) {
        let ids = items.filter { $0.metaID == metaID && $0.state == .completed && (videoId == nil || $0.videoId == videoId) }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids { discard(id) }
        persist()
    }

    /// Removes completed entries whose file was deleted outside the app, unless the library volume itself is
    /// unreachable. Returns the completed items whose file is still missing (shown as unavailable).
    @discardableResult
    func pruneMissingFiles() async -> Set<UUID> {
        let root = libraryRoot()
        let files = items.filter { $0.state == .completed }.map { ($0.id, fileURL(for: $0)) }
        let checked = Set(files.map(\.0))
        let (status, existing) = await Task.detached(priority: .utility) { () -> (LibraryLocation.Status, Set<UUID>) in
            let fm = FileManager.default
            let existing = files.filter { $0.1.map { fm.fileExists(atPath: $0.path) } ?? false }.map(\.0)
            return (LibraryLocation.status(of: root), Set(existing))
        }.value
        let candidates = items.filter { checked.contains($0.id) && $0.state == .completed }
        let pruned = DownloadPruning.missingCompleted(candidates, rootStatus: status) { existing.contains($0.id) }
        if !pruned.isEmpty {
            for id in pruned { discard(id) }
            persist()
        }
        return Set(candidates.map(\.id)).subtracting(existing).subtracting(pruned)
    }

    /// Reattaches to tasks still running in the (background) session and restarts what was interrupted.
    func restore() {
        guard !restored else { return }
        restored = true
        store.cleanUp(keeping: Set(items.map(\.id)))
        Task {
            let running = await session.allTasks
            for task in running {
                guard let download = task as? URLSessionDownloadTask, let desc = task.taskDescription,
                      let id = UUID(uuidString: desc), let i = index(id),
                      [.queued, .downloading, .waiting].contains(items[i].state), tasks[id] == nil,
                      task.state == .running || task.state == .suspended else {
                    if task.state == .running || task.state == .suspended { task.cancel() }
                    continue
                }
                tasks[id] = download
                items[i].state = .downloading
                rates[id] = TransferRateEstimator()
                if task.state == .suspended { task.resume() }
            }
            let orphans = items.filter { DownloadScheduler.isActive($0.state) && tasks[$0.id] == nil && !finishing.contains($0.id) }.map(\.id)
            for id in orphans where store.resumeData(for: id) != nil {
                if let i = index(id) { items[i].state = .queued }
            }
            persist()
            schedule()
            // A force-quit iOS app gets its cancelled tasks' resume data delivered shortly after launch; give that a moment.
            let remaining = orphans.filter { id in index(id).map { DownloadScheduler.isActive(items[$0].state) } ?? false }
            guard !remaining.isEmpty else { return }
            try? await Task.sleep(for: .seconds(factory.isBackground ? 2 : 0))
            for id in remaining {
                guard let i = index(id), DownloadScheduler.isActive(items[i].state), tasks[id] == nil, !finishing.contains(id) else { continue }
                items[i].state = .queued
            }
            persist()
            schedule()
        }
    }

    /// Final file location, for "Show in Finder" / playback of completed items.
    func fileURL(for item: DownloadItem) -> URL? {
        guard item.state == .completed, let filename = item.filename else { return nil }
        return LibraryWriter.folder(for: item.metaID, root: libraryRoot()).appendingPathComponent(filename)
    }

    func bytesPerSecond(for id: UUID) -> Double? { rates[id]?.bytesPerSecond }

    func eta(for item: DownloadItem) -> TimeInterval? {
        guard item.bytesExpected > 0 else { return nil }
        return rates[item.id]?.eta(remaining: item.bytesExpected - item.bytesWritten)
    }

    func isDownloading(videoId: String) -> Bool {
        items.contains { $0.videoId == videoId && [.queued, .downloading, .waiting, .paused].contains($0.state) }
    }

    // MARK: - Scheduling

    private func schedule() {
        guard restored, !terminating else { return }
        let startable = items.filter { !awaitingResumeData.contains($0.id) }
        for id in DownloadScheduler.idsToStart(startable, maxConcurrent: settings.maxConcurrentDownloads) {
            start(id)
        }
    }

    private func start(_ id: UUID) {
        guard let i = index(id), !finishing.contains(id) else { return }
        let item = items[i]
        if let staged = stagedFileURL(of: item), let filename = item.filename {
            if FileManager.default.fileExists(atPath: staged.path) {
                retryInstall(id, staged: staged, filename: filename)
                return
            }
            items[i].stagedFile = nil
        }
        let resumeData = store.resumeData(for: id)
        let remaining = item.bytesExpected - (resumeData == nil ? 0 : item.bytesWritten)
        if let shortfall = spaceShortfall(remaining: remaining, total: item.bytesExpected) {
            fail(id, shortfall.message + " Free up space, then try again.", outOfSpace: true)
            return
        }
        let task: URLSessionDownloadTask
        if let data = resumeData {
            task = session.downloadTask(withResumeData: data)
            startedFromResumeData.insert(id)
        } else {
            guard let url = downloadURL(for: item) else {
                fail(id, "This stream has no downloadable http(s) URL.")
                return
            }
            var request = URLRequest(url: url)
            request.allowsCellularAccess = !settings.downloadOnWiFiOnly
            task = session.downloadTask(with: request)
            startedFromResumeData.remove(id)
            items[i].bytesWritten = 0
        }
        task.taskDescription = id.uuidString
        tasks[id] = task
        validated.remove(id)
        items[i].state = .downloading
        items[i].errorMessage = nil
        rates[id] = TransferRateEstimator()
        task.resume()
        persist()
    }

    /// Drops resume data and re-requests the addon URL, which for Comet re-resolves to a fresh debrid link.
    private func restartFresh(_ id: UUID) {
        guard let i = index(id) else { return }
        tasks.removeValue(forKey: id)?.cancel()
        store.deleteResumeData(for: id)
        freshRetried.insert(id)
        startedFromResumeData.remove(id)
        items[i].state = .queued
        items[i].bytesWritten = 0
        start(id)
    }

    /// Out-of-space failures keep the partial download (resume data) so a retry continues where it stopped.
    private func fail(_ id: UUID, _ message: String, outOfSpace: Bool = false) {
        guard let i = index(id) else { return }
        if let task = tasks.removeValue(forKey: id) {
            if outOfSpace { cancelKeepingResumeData(id, task) } else { task.cancel() }
        }
        items[i].state = .failed
        items[i].errorMessage = message
        items[i].failure = outOfSpace ? .outOfSpace : nil
        rates[id] = nil
        finishing.remove(id)
        persist()
        schedule()
    }

    private func resumeDataDelivered(_ id: UUID) {
        awaitingResumeData.remove(id)
        // Cancelled while the data was in flight: don't leave it behind.
        if index(id) == nil { store.deleteResumeData(for: id) }
        schedule()
    }

    /// After a download is dropped before finishing, deletes its title folder if prepareTitle left only artwork/meta.json there.
    private func removeTitleFolderIfUnused(metaID: String) {
        guard !items.contains(where: { $0.metaID == metaID && $0.state != .completed }) else { return }
        let folder = LibraryWriter.folder(for: metaID, root: libraryRoot())
        chainTitleWork(metaID) {
            await Task.detached(priority: .utility) { LibraryWriter.removeFolderIfUnused(folder) }.value
        }
    }

    /// Serializes folder work per title; finished entries drop out of `prepareTasks`.
    private func chainTitleWork(_ metaID: String, _ work: @escaping @Sendable () async -> Void) {
        let previous = prepareTasks[metaID]
        let task = Task {
            await previous?.value
            await work()
        }
        prepareTasks[metaID] = task
        Task { [weak self] in
            await task.value
            guard let self, self.prepareTasks[metaID] == task else { return }
            self.prepareTasks[metaID] = nil
        }
    }

    private func cancelKeepingResumeData(_ id: UUID, _ task: URLSessionDownloadTask) {
        awaitingResumeData.insert(id)
        let store = store
        task.cancel(byProducingResumeData: { [weak self] data in
            if let data { store.saveResumeData(data, for: id) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.resumeDataDelivered(id) } }
        })
    }

    /// Stops and drops an item with everything it left behind outside the library.
    private func discard(_ id: UUID) {
        guard let i = index(id) else { return }
        tasks.removeValue(forKey: id)?.cancel()
        store.deleteResumeData(for: id)
        deleteStagedFile(of: items[i])
        forget(id)
        items.remove(at: i)
    }

    private func stagedFileURL(of item: DownloadItem) -> URL? {
        guard let name = item.stagedFile, !name.contains("/") else { return nil }
        return store.stagingDirectory.appendingPathComponent(name)
    }

    private func deleteStagedFile(of item: DownloadItem) {
        if let url = stagedFileURL(of: item) { try? FileManager.default.removeItem(at: url) }
    }

    /// Checks every volume the file still has to land on: URLSession's temp dir, staging, then the library.
    private func spaceShortfall(remaining: Int64, total: Int64, alreadyStaged: Bool = false) -> DownloadSpaceCheck.Shortfall? {
        let stages = (alreadyStaged ? [] : [FileManager.default.temporaryDirectory]) + [store.stagingDirectory, libraryRoot()]
        return DownloadSpaceCheck.shortfall(remaining: remaining, total: total, path: stages.compactMap(DiskSpace.volume(at:)))
    }

    private func forget(_ id: UUID) {
        rates[id] = nil
        validated.remove(id)
        startedFromResumeData.remove(id)
        freshRetried.remove(id)
        finishing.remove(id)
    }

    private func handleBadResponse(_ id: UUID, _ problem: DownloadValidation.Problem) {
        if !freshRetried.contains(id), startedFromResumeData.contains(id) || problem.isClientError {
            restartFresh(id)
        } else {
            fail(id, problem.message)
        }
    }

    // MARK: - Session events

    private func handle(_ event: DownloadEvent) {
        switch event {
        case let .progress(id, task, written, expected, response):
            handleProgress(id, task, written, expected, response)
        case let .waiting(id, task):
            guard let uuid = current(id, task), let i = index(uuid), items[i].state == .downloading else { return }
            items[i].state = .waiting
            persist()
        case let .finished(id, task, file, response):
            handleFinished(id, task, file, response)
        case let .stagingFailed(id, task, message, isOutOfSpace):
            guard let uuid = current(id, task) else { return }
            if isOutOfSpace {
                fail(uuid, "The disk ran out of space while saving the download. Free up space, then try again.", outOfSpace: true)
            } else {
                fail(uuid, "Couldn't save the downloaded file: \(message)")
            }
        case let .completed(id, task, error):
            handleCompleted(id, task, error)
        case .backgroundEventsFinished:
            let handler = Self.backgroundCompletionHandler
            Self.backgroundCompletionHandler = nil
            // iOS suspends the app once the handler runs, so let finished files reach the library first.
            let installs = Array(installTasks.values)
            Task {
                for install in installs { await install.value }
                handler?()
            }
        }
    }

    /// The item id for an event, or nil if the event belongs to a task that has since been replaced.
    private func current(_ id: String, _ taskID: Int) -> UUID? {
        guard let uuid = UUID(uuidString: id), index(uuid) != nil else { return nil }
        if let t = tasks[uuid], t.taskIdentifier != taskID { return nil }
        return uuid
    }

    private func handleProgress(_ id: String, _ taskID: Int, _ written: Int64, _ expected: Int64, _ response: DownloadResponseInfo?) {
        guard let uuid = current(id, taskID), tasks[uuid] != nil, let i = index(uuid),
              DownloadScheduler.isActive(items[i].state) else { return }
        if !validated.contains(uuid), let response {
            validated.insert(uuid)
            if let problem = DownloadValidation.check(statusCode: response.statusCode, mimeType: response.mimeType, length: expected) {
                handleBadResponse(uuid, problem)
                return
            }
            if let shortfall = spaceShortfall(remaining: expected - written, total: expected) {
                fail(uuid, shortfall.message + " Free up space, then try again.", outOfSpace: true)
                return
            }
        }
        items[i].bytesWritten = written
        if expected > 0 { items[i].bytesExpected = expected }
        if items[i].state == .waiting { items[i].state = .downloading }
        rates[uuid, default: TransferRateEstimator()].add(bytes: written)
        persistThrottled()
    }

    private func handleFinished(_ id: String, _ taskID: Int, _ file: URL, _ response: DownloadResponseInfo?) {
        guard let uuid = current(id, taskID), let i = index(uuid), DownloadScheduler.isActive(items[i].state) else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        tasks[uuid] = nil
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let problem = DownloadValidation.check(statusCode: response?.statusCode, mimeType: response?.mimeType, length: size) {
            try? FileManager.default.removeItem(at: file)
            handleBadResponse(uuid, problem)
            return
        }
        let item = items[i]
        let filename = DownloadFilename.resolve(
            hint: item.filenameHint, suggested: response?.suggestedFilename, url: URL(string: item.streamURL),
            mimeType: response?.mimeType, title: item.titleName, season: item.season, episode: item.episode
        )
        // Recorded before moving so an install cut short (app suspended or quit) is retried instead of re-downloaded.
        items[i].filename = filename
        items[i].stagedFile = file.lastPathComponent
        persist()
        install(uuid, staged: file, filename: filename, size: size)
    }

    /// Retries moving a file that already downloaded but didn't fit into the library last time.
    private func retryInstall(_ id: UUID, staged: URL, filename: String) {
        guard let i = index(id) else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: staged.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let shortfall = spaceShortfall(remaining: 0, total: size, alreadyStaged: true) {
            fail(id, Self.installOutOfSpaceMessage(shortfall), outOfSpace: true)
            return
        }
        items[i].state = .downloading
        items[i].errorMessage = nil
        items[i].bytesWritten = size
        items[i].bytesExpected = size
        persist()
        install(id, staged: staged, filename: filename, size: size)
    }

    private func install(_ id: UUID, staged file: URL, filename: String, size: Int64) {
        guard let i = index(id) else { return }
        finishing.insert(id)
        let item = items[i]
        let root = libraryRoot()
        let folder = LibraryWriter.folder(for: item.metaID, root: root)
        let sidecarItem = SidecarMeta.SidecarItem(
            videoId: item.videoId, season: item.season, episode: item.episode,
            title: item.episodeTitle ?? item.titleName, file: filename, sizeBytes: size, savedAt: Date()
        )
        let fallback = SidecarMeta(id: item.metaID, type: item.metaType, name: item.titleName, items: [])
        let prepare = prepareTasks[item.metaID]
        installTasks[id] = Task {
            await prepare?.value
            let result = await Task.detached(priority: .utility) {
                try DownloadInstaller.install(staged: file, folder: folder, filename: filename, item: sidecarItem,
                                              fallbackMeta: fallback, root: root)
            }.result
            installTasks[id] = nil
            completeInstall(id, filename: filename, size: size, staged: file, result: result)
        }
    }

    private func completeInstall(_ id: UUID, filename: String, size: Int64, staged: URL, result: Result<Void, Error>) {
        finishing.remove(id)
        guard let i = index(id) else {
            try? FileManager.default.removeItem(at: staged)
            return
        }
        switch result {
        case .success:
            items[i].state = .completed
            items[i].filename = filename
            items[i].stagedFile = nil
            items[i].bytesWritten = size
            items[i].bytesExpected = size
            items[i].errorMessage = nil
            items[i].completedAt = Date()
            // Subtitles (SubtitleSaver, owned by Playback) are fetched in the background and never affect the download.
            SubtitleSaver.saveSubtitles(videoId: items[i].videoId, type: items[i].metaType, file: filename,
                                        folder: LibraryWriter.folder(for: items[i].metaID, root: libraryRoot()),
                                        languages: settings.trackPreferences.subtitleLanguages)
            store.deleteResumeData(for: id)
            forget(id)
            persist()
            onItemCompleted()
            schedule()
        case .failure(let error) where DownloadErrorClassifier.isOutOfSpace(error):
            // Keep the finished file in staging so "Try Again" only has to move it.
            items[i].filename = filename
            items[i].stagedFile = staged.lastPathComponent
            let shortfall = spaceShortfall(remaining: 0, total: size, alreadyStaged: true)
                ?? DownloadSpaceCheck.Shortfall(needed: size, free: DiskSpace.available(at: libraryRoot()) ?? 0, volumeName: nil)
            fail(id, Self.installOutOfSpaceMessage(shortfall), outOfSpace: true)
        case .failure(let error):
            try? FileManager.default.removeItem(at: staged)
            items[i].stagedFile = nil
            fail(id, "Couldn't move the file into the library: \(error.localizedDescription)")
        }
    }

    private func handleCompleted(_ id: String, _ taskID: Int, _ error: DownloadErrorInfo?) {
        guard let error, let uuid = current(id, taskID), let i = index(uuid) else { return }
        if let data = error.resumeData { store.saveResumeData(data, for: uuid) }
        // Paused/failed/cancelled items were stopped by us; their cancellation is expected.
        guard !terminating, DownloadScheduler.isActive(items[i].state), !finishing.contains(uuid) else { return }
        tasks[uuid] = nil
        rates[uuid] = nil
        if error.isCancelled {
            // Not cancelled by us (e.g. the user force-quit the iOS app): continue from resume data.
            items[i].state = .queued
            persist()
            schedule()
        } else if error.isOutOfSpace {
            fail(uuid, Self.outOfSpaceMessage(remaining: items[i].bytesExpected - items[i].bytesWritten), outOfSpace: true)
        } else if startedFromResumeData.contains(uuid), !freshRetried.contains(uuid), !error.isConnectivity {
            restartFresh(uuid)
        } else {
            let resumable = error.resumeData != nil || store.resumeData(for: uuid) != nil
            fail(uuid, resumable ? "\(error.message) Retry to continue where it stopped." : error.message)
        }
    }

    // MARK: - Persistence

    private func persist() {
        lastPersist = Date()
        try? store.saveItems(items)
    }

    private func persistThrottled() {
        if Date().timeIntervalSince(lastPersist) >= 2 { persist() }
    }

    /// Foreground sessions die with the app; grab resume data from running tasks so restore() can continue them.
    private func prepareForTermination() {
        terminating = true
        let group = DispatchGroup()
        let store = store
        for (id, task) in tasks {
            group.enter()
            task.cancel(byProducingResumeData: { data in
                if let data { store.saveResumeData(data, for: id) }
                group.leave()
            })
        }
        _ = group.wait(timeout: .now() + 2)
        persist()
    }

    private func observeSettings() {
        withObservationTracking {
            _ = settings.maxConcurrentDownloads
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.schedule()
                    self?.observeSettings()
                }
            }
        }
    }

    // MARK: - Helpers

    private func index(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func downloadURL(for item: DownloadItem) -> URL? {
        guard let url = URL(string: item.streamURL), let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "http" || scheme == "https" { return url }
        return allowsFileURLs && scheme == "file" ? url : nil
    }

    static func outOfSpaceMessage(remaining: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        let more = remaining > 0 ? " About \(f.string(fromByteCount: remaining)) is still to come." : ""
        return "The disk ran out of space.\(more) Free up space, then try again; the download continues where it stopped."
    }

    static func installOutOfSpaceMessage(_ shortfall: DownloadSpaceCheck.Shortfall) -> String {
        "The download finished, but there isn't room to move it into the library. \(shortfall.message) "
            + "Free up space, then try again; the downloaded file is kept."
    }
}

struct DownloadItem: Codable, Hashable, Sendable, Identifiable {
    enum State: String, Codable, Sendable { case queued, downloading, paused, waiting, completed, failed }
    var id: UUID
    var metaID: String
    var metaType: String
    var titleName: String
    var videoId: String
    var season: Int?
    var episode: Int?
    var episodeTitle: String?
    /// May contain addon secrets (e.g. Comet config): never log or display it.
    var streamURL: String
    var addonName: String
    /// Final file name inside the title folder, set on completion (or once the file is staged).
    var filename: String?
    var state: State
    var bytesWritten: Int64
    var bytesExpected: Int64
    var errorMessage: String?
    var createdAt: Date
    var filenameHint: String? = nil
    var completedAt: Date? = nil
    var failure: Failure? = nil
    /// Name of a fully downloaded file in the staging folder that still has to be moved into the library.
    var stagedFile: String? = nil

    enum Failure: String, Codable, Sendable { case outOfSpace }

    var progress: Double { bytesExpected > 0 ? Double(bytesWritten) / Double(bytesExpected) : 0 }
    var episodeCode: String? { DownloadFilename.episodeCode(season: season, episode: episode) }
}
