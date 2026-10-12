#if os(macOS)
import CoreAudio
import Foundation

/// Watches the system's default audio output and posts `changed` once it has settled on a new device.
/// mpv's coreaudio output stays bound to the device it was opened on, so the player rebuilds it on this signal.
@MainActor
final class AudioOutputMonitor {
    static let shared = AudioOutputMonitor()
    nonisolated static let changed = Notification.Name("AudioOutputMonitor.changed")
    /// `Bool` in `changed`'s userInfo: the previous output disappeared (headphones unplugged, AirPods off).
    nonisolated static let previousDeviceRemovedKey = "previousDeviceRemoved"

    private var device = kAudioObjectUnknown
    private var isListening = false
    private var settleTask: Task<Void, Never>?

    func start() {
        guard !isListening else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, Self.makeListener()) == noErr else { return }
        isListening = true
        device = Self.defaultOutputDevice()
    }

    private nonisolated static func makeListener() -> AudioObjectPropertyListenerBlock {
        { _, _ in MainActor.assumeIsolated { AudioOutputMonitor.shared.defaultOutputChanged() } }
    }

    /// A device going away produces a burst of changes; acting once it settles also keeps the reload clear of
    /// mpv's own device listener, which touches the audio unit the reload disposes of.
    private func defaultOutputChanged() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            let previous = device
            device = Self.defaultOutputDevice()
            guard device != previous else { return }
            let removed = previous != kAudioObjectUnknown && !Self.isAlive(previous)
            NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: [Self.previousDeviceRemovedKey: removed])
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else {
            return kAudioObjectUnknown
        }
        return device
    }

    private static func isAlive(_ device: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }
}
#endif
