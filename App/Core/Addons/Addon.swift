import Foundation

/// A configured addon. `manifestURL` may contain secrets (e.g. a TorBox key inside a Comet URL):
/// it is persisted only in the Keychain and must never be logged; use `redactedURL` for display.
struct Addon: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var manifestURL: String
    var manifest: Manifest
    var enabled: Bool
    var order: Int

    /// Resource base URL: the manifest URL without the trailing `/manifest.json`.
    var baseURL: URL? {
        var s = Addon.normalizeManifestURL(manifestURL)
        if s.hasSuffix("/manifest.json") { s.removeLast("/manifest.json".count) }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    /// Canonical manifest URL: trims whitespace, maps `stremio://` to `https://`, and turns an addon's
    /// configure page (`…/configure`, as Comet links to) into its `…/manifest.json`.
    static func normalizeManifestURL(_ urlString: String) -> String {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("stremio://") { s = "https://" + s.dropFirst("stremio://".count) }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/configure") {
            s.removeLast("/configure".count)
            s += "/manifest.json"
        }
        return s
    }

    /// Host only, safe to show in UI and errors.
    var redactedURL: String { Addon.redact(manifestURL) }

    static func redact(_ urlString: String) -> String {
        guard let u = URL(string: urlString), let host = u.host else { return "<addon>" }
        return "\(u.scheme ?? "https")://\(host)/…"
    }
}
