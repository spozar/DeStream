import Foundation
#if os(macOS)
import CoreServices
#endif

/// Watches folders recursively and calls `onChange` (on the main queue, coalesced by `latency`).
/// macOS uses FSEvents; on iOS only the app writes to the library, so this is a no-op.
/// OWNER: Agent 5 (Library).
final class FolderWatcher: @unchecked Sendable {
    private let onChange: @MainActor @Sendable () -> Void
    #if os(macOS)
    private var stream: FSEventStreamRef?
    #endif

    init(paths: [URL], latency: TimeInterval = 1.0, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
        #if os(macOS)
        start(paths: paths.map(\.path), latency: latency)
        #endif
    }

    deinit { stop() }

    func stop() {
        #if os(macOS)
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        #endif
    }

    #if os(macOS)
    private func start(paths: [String], latency: TimeInterval) {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }
    #endif
}
