#if os(macOS)
import AppKit

/// Asks before quitting while downloads are running; they resume afterwards but may lose the last few seconds.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor var activeDownloadCount: () -> Int = { 0 }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = activeDownloadCount()
        guard count > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = count == 1 ? "A download is in progress" : "\(count) downloads are in progress"
        alert.informativeText = "Downloads pause when DeStream quits and continue the next time you open it."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
#endif
