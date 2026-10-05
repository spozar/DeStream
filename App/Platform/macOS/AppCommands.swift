import SwiftUI

/// Go/View menu commands (macOS menu bar; iPad/iPhone hardware keyboard shortcuts). OWNER: UI Agent 1 (Shell).
struct AppCommands: Commands {
    let services: AppServices

    var body: some Commands {
        CommandMenu("Go") {
            go(.home, key: "1")
            go(.suggestions, key: "2")
            go(.discover, key: "3")
            go(.search, key: "4")
            go(.library, key: "5")
            go(.saved, key: "6")
            go(.downloads, key: "7")
            go(.addons, key: "8")
            Divider()
            Button("Find…") { services.select(.search) }
                .keyboardShortcut("f")
                .disabled(!services.network.isOnline)
        }
        #if os(macOS)
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { services.select(.settings) }
                .keyboardShortcut(",")
        }
        #endif
        CommandGroup(before: .sidebar) {
            Button("Reload") { services.reload() }
                .keyboardShortcut("r")
            Divider()
        }
    }

    private func go(_ section: AppSection, key: KeyEquivalent) -> some View {
        Button(section.title) { services.select(section) }
            .keyboardShortcut(key)
            .disabled(section.requiresNetwork && !services.network.isOnline
                      || section.requiresAccount && !services.account.isSignedIn)
    }
}
