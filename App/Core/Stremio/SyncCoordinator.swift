import Foundation
import Observation

/// Decides when to sync (launch, foreground, reconnect, periodic, after local changes) and exposes status. OWNER: Stremio Agent 5 (Account/UI).
@MainActor @Observable
final class SyncCoordinator {
    @ObservationIgnored let account: StremioAccount
    @ObservationIgnored let addonSync: AddonSync
    @ObservationIgnored let librarySync: LibrarySync
    @ObservationIgnored let network: NetworkMonitor

    private(set) var isSyncing = false
    private(set) var lastSyncedAt: Date? {
        didSet { defaults.set(lastSyncedAt, forKey: Self.lastSyncedKey) }
    }
    private(set) var lastError: String?

    /// One full sync pass. Replaceable for tests.
    @ObservationIgnored var syncAction: @MainActor () async throws -> Void
    @ObservationIgnored var isSignedIn: @MainActor () -> Bool
    /// Called after sign-out (or an expired session) to drop account-only local state.
    @ObservationIgnored var onSignedOut: (@MainActor () -> Void)?
    @ObservationIgnored var debounceInterval: Duration = .seconds(3)
    @ObservationIgnored var periodicInterval: Duration = .seconds(300)
    /// Foreground/background triggers are skipped when the last successful sync is more recent than this.
    @ObservationIgnored var freshnessInterval: TimeInterval = 30

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var started = false
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var wasSignedIn = false
    @ObservationIgnored private var wasOnline = true
    @ObservationIgnored private var rerunRequested = false
    /// Requests that arrived while a sync was running and are waiting on it (for tests).
    @ObservationIgnored private(set) var pendingRequests = 0
    @ObservationIgnored private var hasPendingChanges = false
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?

    private static let lastSyncedKey = "stremio.lastSyncedAt"

    init(account: StremioAccount, addonSync: AddonSync, librarySync: LibrarySync, network: NetworkMonitor,
         defaults: UserDefaults = .standard) {
        self.account = account
        self.addonSync = addonSync
        self.librarySync = librarySync
        self.network = network
        self.defaults = defaults
        lastSyncedAt = defaults.object(forKey: Self.lastSyncedKey) as? Date
        isSignedIn = { account.isSignedIn }
        syncAction = {
            // Addons wait until the user decides how to combine this device's addons with the account's.
            if !addonSync.needsFirstSyncChoice { try await addonSync.sync() }
            try await librarySync.sync()
        }
    }

    func start() {
        guard !started else { return }
        started = true
        wasSignedIn = isSignedIn()
        wasOnline = network.isOnline
        observeAccount()
        observeNetwork()
        if wasSignedIn {
            startPeriodic()
            Task { await syncNow() }
        }
    }

    func syncNow() async {
        guard isSignedIn() else { return }
        debounceTask?.cancel()
        debounceTask = nil
        if let running {
            rerunRequested = true
            pendingRequests += 1
            await running.value
            pendingRequests -= 1
            return
        }
        let task = Task { await runLoop() }
        running = task
        await task.value
    }

    /// Debounced sync after a local change (addon edit, playback stopped, bookmark toggled).
    func scheduleSync() {
        guard isSignedIn() else { return }
        hasPendingChanges = true
        debounceTask?.cancel()
        let delay = debounceInterval
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            await self.syncNow()
        }
    }

    /// Signs out of the account; local data stays on this device.
    func signOut() async {
        await account.logout()
        handleSignedInChange(false)
    }

    // MARK: - App lifecycle

    func sceneDidBecomeActive() {
        isActive = true
        guard started, isSignedIn() else { return }
        startPeriodic()
        if !isFresh { Task { await syncNow() } }
    }

    /// Best-effort final sync when backgrounding or quitting, bounded by `timeout`.
    func sceneDidEnterBackground(timeout: Duration = .seconds(5)) async {
        isActive = false
        stopPeriodic()
        guard isSignedIn(), network.isOnline, hasPendingChanges || !isFresh || debounceTask != nil else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.syncNow() }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Internals

    private var isFresh: Bool {
        guard let lastSyncedAt else { return false }
        return Date().timeIntervalSince(lastSyncedAt) < freshnessInterval
    }

    private func runLoop() async {
        isSyncing = true
        repeat {
            rerunRequested = false
            hasPendingChanges = false
            await performOnce()
        } while rerunRequested && isSignedIn() && !Task.isCancelled
        isSyncing = false
        running = nil
    }

    private func performOnce() async {
        do {
            try await syncAction()
            guard isSignedIn() else { return }
            lastSyncedAt = Date()
            lastError = nil
        } catch is CancellationError {
        } catch {
            if (error as? StremioAPIError) == .unauthorized {
                account.handleUnauthorized()
                handleSignedInChange(isSignedIn())
            }
            guard isSignedIn() else { return }
            lastError = Self.friendlyMessage(for: error)
        }
    }

    static func friendlyMessage(for error: Error) -> String {
        if let apiError = error as? StremioAPIError {
            switch apiError {
            case .notImplemented: return "Sync isn't available yet."
            case .server(let message) where !message.isEmpty: return "Stremio couldn't sync: \(message)"
            default: return apiError.errorDescription ?? "Sync failed."
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "You're offline. Sync will resume when you're back online."
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Couldn't reach Stremio. Try again in a moment."
            default:
                return "Couldn't reach Stremio. Check your connection."
            }
        }
        if error is DecodingError { return "Stremio sent an unexpected response. Try again later." }
        return "Sync failed. Try again later."
    }

    func handleSignedInChange(_ signedIn: Bool) {
        guard signedIn != wasSignedIn else { return }
        wasSignedIn = signedIn
        if signedIn {
            lastError = nil
            if started && isActive {
                startPeriodic()
                Task { await syncNow() }
            }
        } else {
            stopPeriodic()
            debounceTask?.cancel()
            debounceTask = nil
            running?.cancel()
            rerunRequested = false
            hasPendingChanges = false
            lastSyncedAt = nil
            lastError = nil
            onSignedOut?()
        }
    }

    func handleOnlineChange(_ online: Bool) {
        defer { wasOnline = online }
        guard online, !wasOnline, started, isActive, isSignedIn() else { return }
        Task { await syncNow() }
    }

    private func observeAccount() {
        let signedIn = withObservationTracking { isSignedIn() } onChange: { [weak self] in
            Task { @MainActor in self?.observeAccount() }
        }
        handleSignedInChange(signedIn)
    }

    private func observeNetwork() {
        let online = withObservationTracking { network.isOnline } onChange: { [weak self] in
            Task { @MainActor in self?.observeNetwork() }
        }
        handleOnlineChange(online)
    }

    private func startPeriodic() {
        guard periodicTask == nil else { return }
        let interval = periodicInterval
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                if self.isActive, self.network.isOnline, self.isSignedIn() { await self.syncNow() }
            }
        }
    }

    private func stopPeriodic() {
        periodicTask?.cancel()
        periodicTask = nil
    }
}
