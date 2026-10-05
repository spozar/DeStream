#if os(iOS)
import AVFoundation

/// `.playback` category so audio keeps playing with the screen locked or the mute switch on.
enum PlayerAudioSession {
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("[PlayerAudioSession] activate failed: \(error.localizedDescription)")
            #endif
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Calls `pause` when headphones are unplugged or a call/alarm interrupts audio. mpv doesn't do this itself, and
    /// AVPlayer pausing on its own would leave the engine's state (and the play button) out of sync.
    @MainActor static func observePauseEvents(_ pause: @escaping @MainActor @Sendable () -> Void) -> [NSObjectProtocol] {
        let center = NotificationCenter.default
        let route = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { pause() }
        }
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            MainActor.assumeIsolated { pause() }
        }
        return [route, interruption]
    }
}
#endif
