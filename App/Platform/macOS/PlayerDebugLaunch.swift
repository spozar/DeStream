#if os(macOS)
import AppKit
import SwiftUI

/// Player menu commands. In DEBUG builds also:
/// - `-DeStreamPlayURL <url|path>` opens the player window for that URL right after launch
///   (optional `-DeStreamPlayStart <seconds>`, `-DeStreamPlayTitle <title>`,
///   `-DeStreamPlayCloseAfter <seconds>` + `-DeStreamPlayCycles <n>` to stress-test window close/teardown);
/// - Debug ▸ Play URL from Clipboard (⌥⌘V).
struct PlayerCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        #if DEBUG
        let _ = PlayerDebugLaunch.openFromLaunchArgumentsOnce(openWindow)
        CommandMenu("Debug") {
            Button("Play URL from Clipboard") {
                if let text = NSPasteboard.general.string(forType: .string),
                   let request = PlayerDebugLaunch.request(for: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    openWindow(id: "player", value: request)
                }
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
        }
        #else
        CommandGroup(after: .windowArrangement) {}
        #endif
    }
}

#if DEBUG
@MainActor
enum PlayerDebugLaunch {
    private static var didOpen = false

    static func openFromLaunchArgumentsOnce(_ openWindow: OpenWindowAction) {
        guard !didOpen else { return }
        didOpen = true
        let defaults = UserDefaults.standard
        guard let value = defaults.string(forKey: "DeStreamPlayURL"), var request = request(for: value) else { return }
        if let title = defaults.string(forKey: "DeStreamPlayTitle") { request.title = title }
        if defaults.object(forKey: "DeStreamPlayStart") != nil { request.startAt = defaults.double(forKey: "DeStreamPlayStart") }
        let closeAfter = defaults.double(forKey: "DeStreamPlayCloseAfter")
        let cycles = max(1, defaults.integer(forKey: "DeStreamPlayCycles"))
        print("[DeStream] debug launch: opening player for \(request.title)")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            for cycle in 1...cycles {
                var r = request
                r.id = UUID()
                openWindow(id: "player", value: r)
                guard closeAfter > 0 else { return }
                try? await Task.sleep(for: .seconds(closeAfter))
                print("[DeStream] debug launch: closing player window (cycle \(cycle)/\(cycles))")
                NSApp.windows.first { $0.title == r.title && $0.isVisible }?.performClose(nil)
                try? await Task.sleep(for: .seconds(1))
            }
            print("[DeStream] debug launch: done")
        }
    }

    static func request(for value: String) -> PlaybackRequest? {
        let url: URL
        if value.hasPrefix("/") || value.hasPrefix("~") {
            url = URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
        } else if let u = URL(string: value), u.scheme != nil {
            url = u
        } else {
            return nil
        }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return PlaybackRequest(
            url: url, title: name.isEmpty ? "Debug Stream" : name, subtitle: "Debug playback",
            metaID: "debug", metaType: "movie", videoId: "debug:\(name)", isLocal: false,
            filenameHint: name, posterURL: nil, bingeGroup: nil, skipsHistory: true
        )
    }
}
#endif
#endif
