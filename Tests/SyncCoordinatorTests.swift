import XCTest
@testable import DeStream

@MainActor
final class SyncCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SyncCoordinatorTests-\(UUID().uuidString)")
        suiteName = "SyncCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeCoordinator(signedIn: Bool = true) -> (SyncCoordinator, Counter) {
        let account = StremioAccount(keychainKey: "test.\(UUID().uuidString)")
        let store = AddonStore(load: { nil }, save: { _ in }, loadPendingDefaults: { nil }, savePendingDefaults: { _ in })
        let registry = AddonRegistry(store: store, defaultManifestURLs: [])
        let progress = ProgressStore(fileURL: tempDir.appendingPathComponent("progress.json"))
        let coordinator = SyncCoordinator(
            account: account,
            addonSync: AddonSync(account: account, registry: registry),
            librarySync: LibrarySync(account: account, progress: progress),
            network: NetworkMonitor(),
            defaults: defaults
        )
        let counter = Counter()
        counter.signedIn = signedIn
        coordinator.isSignedIn = { counter.signedIn }
        coordinator.syncAction = {
            counter.calls += 1
            try await Task.sleep(for: counter.delay)
            if let error = counter.error { throw error }
        }
        coordinator.debounceInterval = .milliseconds(50)
        return (coordinator, counter)
    }

    func testSyncNowRecordsSuccess() async {
        let (sync, counter) = makeCoordinator()
        await sync.syncNow()
        XCTAssertEqual(counter.calls, 1)
        XCTAssertNotNil(sync.lastSyncedAt)
        XCTAssertNil(sync.lastError)
        XCTAssertFalse(sync.isSyncing)
    }

    func testSignedOutDoesNothing() async {
        let (sync, counter) = makeCoordinator(signedIn: false)
        await sync.syncNow()
        sync.scheduleSync()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counter.calls, 0)
        XCTAssertNil(sync.lastSyncedAt)
    }

    func testConcurrentRequestsCoalesce() async {
        let (sync, counter) = makeCoordinator()
        let gate = Gate()
        sync.syncAction = {
            counter.calls += 1
            if counter.calls == 1 { await gate.wait() }
        }
        let first = Task { await sync.syncNow() }
        while counter.calls == 0 { await Task.yield() }
        XCTAssertTrue(sync.isSyncing)
        // Both requests arrive while the first run is blocked; syncNow registers them before suspending.
        let second = Task { await sync.syncNow() }
        let third = Task { await sync.syncNow() }
        while sync.pendingRequests < 2 { await Task.yield() }
        gate.open()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(counter.calls, 2)
        XCTAssertFalse(sync.isSyncing)
    }

    func testScheduleSyncDebounces() async {
        let (sync, counter) = makeCoordinator()
        for _ in 0..<5 { sync.scheduleSync() }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.calls, 1)
    }

    func testErrorIsFriendlyAndCleared() async {
        let (sync, counter) = makeCoordinator()
        counter.error = URLError(.notConnectedToInternet)
        await sync.syncNow()
        XCTAssertEqual(sync.lastError, "You're offline. Sync will resume when you're back online.")
        XCTAssertNil(sync.lastSyncedAt)

        counter.error = nil
        await sync.syncNow()
        XCTAssertNil(sync.lastError)
        XCTAssertNotNil(sync.lastSyncedAt)
    }

    func testSignOutClearsStatusAndCallsHandler() async {
        let (sync, counter) = makeCoordinator(signedIn: false)
        var signedOutCalls = 0
        sync.onSignedOut = { signedOutCalls += 1 }
        counter.signedIn = true
        sync.handleSignedInChange(true)
        await sync.syncNow()
        XCTAssertNotNil(sync.lastSyncedAt)

        counter.signedIn = false
        sync.handleSignedInChange(false)
        sync.handleSignedInChange(false)
        XCTAssertNil(sync.lastSyncedAt)
        XCTAssertNil(sync.lastError)
        XCTAssertEqual(signedOutCalls, 1)
    }

    func testLastSyncedPersists() async {
        let (sync, _) = makeCoordinator()
        await sync.syncNow()
        let (reloaded, _) = makeCoordinator()
        XCTAssertEqual(reloaded.lastSyncedAt, sync.lastSyncedAt)
    }

    func testFriendlyMessagesNeverExposeRawErrors() {
        XCTAssertEqual(SyncCoordinator.friendlyMessage(for: StremioAPIError.unauthorized),
                       "Your Stremio session has expired. Sign in again.")
        XCTAssertEqual(SyncCoordinator.friendlyMessage(for: CocoaError(.fileReadCorruptFile)), "Sync failed. Try again later.")
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class Counter {
    var calls = 0
    var signedIn = true
    var delay: Duration = .zero
    var error: Error?
}
