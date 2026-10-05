import Foundation

/// The only place where downloads differ per platform: session configuration, termination hook and free-space key.
struct DownloadSessionFactory: Sendable {
    static let backgroundIdentifier = "se.mediaempire.DeStream.downloads"

    /// Background sessions keep running while the app is suspended or terminated by the system.
    var isBackground: Bool
    /// Posted when the app is about to quit; foreground sessions use it to save resume data.
    var terminationNotification: Notification.Name?
    var makeConfiguration: @Sendable (_ allowsCellularAccess: Bool) -> URLSessionConfiguration

    static let foreground = DownloadSessionFactory(
        isBackground: false,
        terminationNotification: Notification.Name("NSApplicationWillTerminateNotification"),
        makeConfiguration: { cellular in
            let c = URLSessionConfiguration.default
            c.waitsForConnectivity = true
            c.allowsCellularAccess = cellular
            c.timeoutIntervalForRequest = 60
            c.timeoutIntervalForResource = 7 * 24 * 3600
            return c
        }
    )

    static let background = DownloadSessionFactory(
        isBackground: true,
        terminationNotification: nil,
        makeConfiguration: { cellular in
            let c = URLSessionConfiguration.background(withIdentifier: backgroundIdentifier)
            c.isDiscretionary = false
            c.sessionSendsLaunchEvents = true
            c.allowsCellularAccess = cellular
            return c
        }
    )

    static var platformDefault: DownloadSessionFactory {
        #if os(iOS)
        background
        #else
        foreground
        #endif
    }
}

enum DiskSpace {
    /// Free bytes on the volume containing `url` (or its nearest existing ancestor).
    static func available(at url: URL) -> Int64? {
        let u = nearestExisting(url)
        #if os(iOS)
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        #else
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        #endif
    }

    /// Free space plus identity of the volume holding `url`, for comparing stages of a download.
    static func volume(at url: URL) -> DownloadSpaceCheck.Volume? {
        let u = nearestExisting(url)
        guard let free = available(at: u) else { return nil }
        let values = try? u.resourceValues(forKeys: [.volumeURLKey, .volumeLocalizedNameKey])
        #if os(iOS)
        let name: String? = nil
        #else
        let name = values?.volumeLocalizedName
        #endif
        return DownloadSpaceCheck.Volume(id: values?.volume?.path ?? u.path, name: name, free: free)
    }

    private static func nearestExisting(_ url: URL) -> URL {
        var u = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 {
            u = u.deletingLastPathComponent()
        }
        return u
    }
}
