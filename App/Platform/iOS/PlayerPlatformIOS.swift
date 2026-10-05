#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Hosts mpv's CAMetalLayer as a sublayer and keeps its drawable size in sync with the view.
struct MPVVideoView: UIViewRepresentable {
    let controller: MPVPlayerController

    func makeUIView(context: Context) -> MPVHostView { MPVHostView(controller: controller) }
    func updateUIView(_ uiView: MPVHostView, context: Context) {}
}

final class MPVHostView: UIView {
    private let controller: MPVPlayerController
    private var metalLayer: MPVMetalLayer { controller.layer }

    init(controller: MPVPlayerController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.nativeScale ?? traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        CATransaction.commit()
        controller.setDrawableSize(CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }
}

struct AVVideoView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> AVHostView {
        let view = AVHostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: AVHostView, context: Context) {}
}

final class AVHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// iOS players are always presented full screen (fullScreenCover); nothing to toggle.
@MainActor @Observable
final class PlayerWindowState {
    static let supportsFullScreenToggle = false
    let isFullScreen = true
    func toggleFullScreen() {}
    func exitFullScreen() {}
    @discardableResult func closeWindow() -> Bool { false }
    func setChromeVisible(_ visible: Bool) {}
}

extension View {
    func playerWindow(_ state: PlayerWindowState) -> some View { self }
}

enum PlayerPlatform {
    @MainActor private static var activeCount = 0

    /// Disables auto-lock while any player is open. Calls must be balanced.
    @MainActor static func setPlaybackActive(_ active: Bool) {
        activeCount = max(0, activeCount + (active ? 1 : -1))
        UIApplication.shared.isIdleTimerDisabled = activeCount > 0
    }

    static let willTerminateNotification = UIApplication.willTerminateNotification

    /// Orientations the app allows right now; the player widens it to landscape while it's on screen.
    @MainActor static var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown

    /// Rotates into landscape when the player opens and back to portrait when it closes.
    @MainActor static func setPlayerPresented(_ presented: Bool) {
        orientationMask = presented ? .landscape : .allButUpsideDown
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            window.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: presented ? .landscapeRight : .portrait)) { _ in }
    }
}
#endif
