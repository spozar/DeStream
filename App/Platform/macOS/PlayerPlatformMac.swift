#if os(macOS)
import AppKit
import AVFoundation
import SwiftUI

/// Hosts mpv's CAMetalLayer (layer-hosting view) and keeps its drawable size in sync with the view.
struct MPVVideoView: NSViewRepresentable {
    let controller: MPVPlayerController

    func makeNSView(context: Context) -> MPVHostView { MPVHostView(controller: controller) }
    func updateNSView(_ nsView: MPVHostView, context: Context) {}
}

final class MPVHostView: NSView {
    private let controller: MPVPlayerController
    private var metalLayer: MPVMetalLayer { controller.layer }

    init(controller: MPVPlayerController) {
        self.controller = controller
        super.init(frame: .zero)
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); updateDrawable() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateDrawable() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDrawable() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateDrawable() }

    private func updateDrawable() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        CATransaction.commit()
        controller.setDrawableSize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
}

struct AVVideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVHostView { AVHostView(player: player) }
    func updateNSView(_ nsView: AVHostView, context: Context) {}
}

final class AVHostView: NSView {
    init(player: AVPlayer) {
        super.init(frame: .zero)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Tracks the player's NSWindow: fullscreen, title-bar buttons, restoration.
@MainActor @Observable
final class PlayerWindowState {
    static let supportsFullScreenToggle = true
    private(set) var isFullScreen = false
    @ObservationIgnored weak var window: NSWindow? {
        didSet { if window !== oldValue { attach() } }
    }
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    func toggleFullScreen() { window?.toggleFullScreen(nil) }
    func exitFullScreen() { if isFullScreen { window?.toggleFullScreen(nil) } }
    /// Closes the player window; returns true when there was a window to close.
    @discardableResult func closeWindow() -> Bool {
        guard let window else { return false }
        NSCursor.setHiddenUntilMouseMoves(false)
        window.close()
        return true
    }

    /// Hides the traffic lights together with the overlay controls.
    func setChromeVisible(_ visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
        // Only when the pointer is over this player; otherwise it would vanish over other windows of the app.
        if !visible, let window, window.isKeyWindow, window.frame.contains(NSEvent.mouseLocation) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func attach() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        guard let window else { return }
        window.isRestorable = false
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        isFullScreen = window.styleMask.contains(.fullScreen)
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isFullScreen = self?.window?.styleMask.contains(.fullScreen) ?? false }
            })
        }
    }
}

private struct WindowReader: NSViewRepresentable {
    let state: PlayerWindowState

    func makeNSView(context: Context) -> NSView { ReaderView(state: state) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        let state: PlayerWindowState
        init(state: PlayerWindowState) { self.state = state; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { state.window = window }
        }
    }
}

extension View {
    func playerWindow(_ state: PlayerWindowState) -> some View {
        background(WindowReader(state: state).frame(width: 0, height: 0))
    }
}

enum PlayerPlatform {
    @MainActor private static var activity: NSObjectProtocol?
    @MainActor private static var activeCount = 0

    /// Keeps the display awake while any player is open. Calls must be balanced.
    /// iOS rotates to landscape for the player; windows on macOS need nothing.
    @MainActor static func setPlayerPresented(_ presented: Bool) {}

    @MainActor static func setPlaybackActive(_ active: Bool) {
        activeCount = max(0, activeCount + (active ? 1 : -1))
        if activeCount > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Video playback")
        } else if activeCount == 0, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    static let willTerminateNotification = NSApplication.willTerminateNotification
}

enum PlayerAudioSession {
    static func activate() {}
    static func deactivate() {}
    @MainActor static func observePauseEvents(_ pause: @escaping @MainActor @Sendable () -> Void) -> [NSObjectProtocol] { [] }
}
#endif
