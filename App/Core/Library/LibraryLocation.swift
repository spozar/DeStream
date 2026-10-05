import Foundation

/// Resolves the library root per platform. OWNER: Agent 5 (Library).
enum LibraryLocation {
    /// macOS: ~/Movies/DeStream (or override). iOS: Application Support/Library, excluded from backup.
    static func root(override: String? = nil) -> URL {
        if let override, !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        #if os(macOS)
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        return movies.appendingPathComponent("DeStream", isDirectory: true)
        #else
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Library", isDirectory: true)
        #endif
    }

    enum Status: Equatable, Sendable {
        case exists
        /// Root not created yet but could be (nothing saved).
        case empty
        /// Root lives on a volume that is not mounted (e.g. unplugged external drive), or is not a folder.
        case unavailable
    }

    static func status(of root: URL) -> Status {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDir) { return isDir.boolValue ? .exists : .unavailable }
        let components = root.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes",
           !fm.fileExists(atPath: "/Volumes/" + components[2]) {
            return .unavailable
        }
        return .empty
    }

    /// Creates the root if needed. On iOS it is excluded from iCloud backup.
    static func ensureRoot(_ root: URL) throws {
        if status(of: root) == .unavailable { throw LibraryError.libraryUnavailable }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #if os(iOS)
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }
}
