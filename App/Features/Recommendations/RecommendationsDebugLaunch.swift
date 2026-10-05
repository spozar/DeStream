#if DEBUG && os(macOS)
import AppKit
import SwiftUI

/// DEBUG-only visual-check harness for For You (macOS).
///
///     DeStream -DeStreamOpenSuggestions tmdb|cinemeta|fallback|loading|nohistory|failed [-DeStreamSuggestionsSize 900x2400]
///     DeStream -DSSection suggestions -DeStreamOpenSuggestions live -DeStreamSuggestionsSize 900x700
///
/// Sample states open in an extra window fed by `RecommendationsSample` (Cinemeta only for artwork, no Keychain access).
/// `live` resizes the main window instead. Heights taller than the screen use a borderless window so the whole page fits.
@_cdecl("DeStreamSuggestionsDebugInstall")
func deStreamSuggestionsDebugInstall() {
    guard let mode = UserDefaults.standard.string(forKey: "DeStreamOpenSuggestions") else { return }
    NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { SuggestionsDebugLaunch.open(mode) }
    }
}

@MainActor
enum SuggestionsDebugLaunch {
    private static var window: NSWindow?

    private static var size: CGSize {
        let parts = (UserDefaults.standard.string(forKey: "DeStreamSuggestionsSize") ?? "1320x880")
            .split(separator: "x").compactMap { Double($0) }
        return parts.count == 2 ? CGSize(width: parts[0], height: parts[1]) : CGSize(width: 1320, height: 880)
    }

    static func open(_ mode: String) {
        if mode == "live" {
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard let main = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                if size.height > (main.screen?.visibleFrame.height ?? 0) { main.styleMask = [.borderless, .resizable] }
                main.setFrame(NSRect(origin: CGPoint(x: 40, y: 40), size: size), display: true)
            }
            return
        }

        let registry = AddonRegistry(store: AddonStore(load: { nil }, save: { _ in }))
        Task { await registry.installDefaultsIfNeeded() }

        let root = NavigationStack {
            RecommendationsContent(state: RecommendationsSample.state(named: mode), actions: .none)
                .routeDestinations()
        }
        .environment(registry)

        let tall = size.height > (NSScreen.main?.visibleFrame.height ?? 900)
        let w = NSWindow(contentRect: NSRect(origin: CGPoint(x: 60, y: 60), size: size),
                         styleMask: tall ? [.borderless] : [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "SuggestionsDebug"
        w.titlebarAppearsTransparent = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = NSHostingView(rootView: root)
        w.isReleasedWhenClosed = false
        w.setFrame(NSRect(origin: CGPoint(x: 60, y: 60), size: size), display: true)
        w.orderFront(nil)
        window = w
    }
}
#endif
