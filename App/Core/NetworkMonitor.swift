import Foundation
import Network
import Observation

/// Online/offline state via NWPathMonitor. OWNER: Agent 6 (Shell).
@MainActor @Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    private(set) var isExpensive = false
    /// False until the first path update arrives; before that `isOnline` is an optimistic guess.
    private(set) var hasResolved = false
    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor in
                guard let self else { return }
                self.isOnline = online
                self.isExpensive = expensive
                self.hasResolved = true
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
    }

    deinit { monitor.cancel() }
}
