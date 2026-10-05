import SwiftUI

@main
struct DeStreamApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif
    @State private var services = AppServices()

    init() {
        #if os(macOS)
        // Restored window state can bring back only a stale player window and no main window.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
        #endif
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        #if os(macOS)
        // A single main window: section selection lives in the shared `AppServices`, so a second main window
        // would mirror the first. Closed, it comes back from the Dock or the Window menu.
        Window("DeStream", id: "main") { mainContent }
            .onChange(of: scenePhase) { _, phase in sceneDidChange(phase) }
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1320, height: 840)
            .commands { AppCommands(services: services) }
        #else
        WindowGroup { mainContent }
            .onChange(of: scenePhase) { _, phase in sceneDidChange(phase) }
            .commands { AppCommands(services: services) }
        #endif

        #if os(macOS)
        WindowGroup("Player", id: "player", for: PlaybackRequest.self) { $request in
            if let request {
                PlayerView(request: request)
                    .environment(services)
                    .environment(services.settings)
                    .environment(services.library)
                    .environment(services.progress)
                    .environment(services.librarySync)
                    .environment(services.sync)
                    .frame(minWidth: 480, minHeight: 270)
                    .background(Color.black)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 720)
        .commands { PlayerCommands() }

        #endif
    }

    private var mainContent: some View {
        RootView()
            .accountOnboarding()
            .environment(services)
            .environment(services.settings)
            .environment(services.registry)
            .environment(services.library)
            .environment(services.progress)
            .environment(services.downloads)
            .environment(services.network)
            .environment(services.account)
            .environment(services.addonSync)
            .environment(services.librarySync)
            .environment(services.sync)
            .environment(services.tmdb)
            .environment(services.recommendations)
            .task {
                #if os(macOS)
                appDelegate.activeDownloadCount = { [services] in services.activeDownloadCount }
                #endif
                await services.start()
            }
            .tint(Theme.Palette.accent)
            .preferredColorScheme(.dark)
    }

    private func sceneDidChange(_ phase: ScenePhase) {
        if phase == .active {
            services.sync.sceneDidBecomeActive()
        } else {
            Task { await flushInBackground() }
        }
    }

    private func flushInBackground() async {
        #if os(iOS)
        await AppDelegate.withBackgroundTime { await services.flush() }
        #else
        await services.flush()
        #endif
    }
}
