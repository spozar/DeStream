#if os(iOS)
import UIKit

/// Handles background URLSession events. OWNER: Agent 4 (Downloads) for session handling, Agent 3 for audio session.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { PlayerPlatform.orientationMask }
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        handleBackgroundDownloadEvents(identifier: identifier, completionHandler: completionHandler)
    }

    /// Runs `work` while asking iOS for extra background time, so a final sync can finish after the app is backgrounded.
    @MainActor
    static func withBackgroundTime(_ work: @MainActor () async -> Void) async {
        let token = BackgroundTaskToken()
        token.begin()
        await work()
        token.end()
    }

    // MARK: - Background downloads (Agent 4)

    /// The DownloadManager recreates the session with this identifier at launch; it calls the handler from
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` once all events are delivered.
    private func handleBackgroundDownloadEvents(identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == DownloadSessionFactory.backgroundIdentifier else {
            completionHandler()
            return
        }
        DownloadManager.backgroundCompletionHandler = completionHandler
    }
}

@MainActor
private final class BackgroundTaskToken {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Flush") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
