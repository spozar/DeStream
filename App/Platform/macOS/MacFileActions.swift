#if os(macOS)
import AppKit

/// Finder / open-panel helpers used by Settings. OWNER: Agent 6 (Shell).
@MainActor
enum MacFileActions {
    static func chooseDirectory(startingAt url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose where DeStream keeps saved titles."
        panel.directoryURL = url
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
#endif
