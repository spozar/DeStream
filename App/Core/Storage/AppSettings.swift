import Foundation
import Observation

/// Non-secret user settings persisted in UserDefaults. OWNER: Agent 1 (Core).
@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    /// Absolute path override for the library root (macOS only); nil = platform default.
    var libraryPathOverride: String? {
        didSet { defaults.set(libraryPathOverride, forKey: "libraryPathOverride") }
    }
    var maxConcurrentDownloads: Int {
        didSet { defaults.set(maxConcurrentDownloads, forKey: "maxConcurrentDownloads") }
    }
    var downloadOnWiFiOnly: Bool {
        didSet { defaults.set(downloadOnWiFiOnly, forKey: "downloadOnWiFiOnly") }
    }
    /// Prefer the mpv engine; AVPlayer is used for mp4/m3u8 only when false.
    var preferMPV: Bool {
        didSet { defaults.set(preferMPV, forKey: "preferMPV") }
    }
    /// ISO 639-1 code; "" keeps the file's original audio.
    var audioLanguage: String {
        didSet { defaults.set(audioLanguage, forKey: "audioLanguage") }
    }
    var subtitleMode: SubtitleMode {
        didSet { defaults.set(subtitleMode.rawValue, forKey: "subtitleMode") }
    }
    var subtitleLanguage: String {
        didSet {
            defaults.set(subtitleLanguage, forKey: "subtitleLanguage")
            if subtitleFallbackLanguage == subtitleLanguage { subtitleFallbackLanguage = "" }
        }
    }
    /// Used when no subtitle exists in `subtitleLanguage`; "" for none.
    var subtitleFallbackLanguage: String {
        didSet { defaults.set(subtitleFallbackLanguage, forKey: "subtitleFallbackLanguage") }
    }

    /// Order and visibility of Home rows.
    var homeRows: HomeRowPrefs {
        didSet {
            guard homeRows != oldValue, let data = try? JSONEncoder().encode(homeRows) else { return }
            defaults.set(data, forKey: "homeRows")
        }
    }

    var trackPreferences: TrackPreferences {
        TrackPreferences(
            audioLanguage: audioLanguage.isEmpty ? nil : audioLanguage,
            subtitleMode: subtitleMode,
            subtitleLanguages: [subtitleLanguage, subtitleFallbackLanguage].filter { !$0.isEmpty }.reduce(into: []) { list, code in
                if !list.contains(code) { list.append(code) }
            }
        )
    }

    /// The device language when it's one we know, otherwise English.
    static var deviceLanguage: String {
        let code = LanguageCodes.canonical(Locale.preferredLanguages.first) ?? "en"
        return LanguageCodes.common.contains(code) ? code : "en"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        libraryPathOverride = defaults.string(forKey: "libraryPathOverride")
        let m = defaults.integer(forKey: "maxConcurrentDownloads")
        maxConcurrentDownloads = m > 0 ? m : 2
        downloadOnWiFiOnly = defaults.object(forKey: "downloadOnWiFiOnly") as? Bool ?? true
        preferMPV = defaults.object(forKey: "preferMPV") as? Bool ?? true
        audioLanguage = defaults.string(forKey: "audioLanguage") ?? ""
        subtitleMode = defaults.string(forKey: "subtitleMode").flatMap(SubtitleMode.init(rawValue:)) ?? .off
        subtitleLanguage = defaults.string(forKey: "subtitleLanguage") ?? Self.deviceLanguage
        subtitleFallbackLanguage = defaults.string(forKey: "subtitleFallbackLanguage") ?? (Self.deviceLanguage == "en" ? "" : "en")
        homeRows = defaults.data(forKey: "homeRows").flatMap { try? JSONDecoder().decode(HomeRowPrefs.self, from: $0) } ?? HomeRowPrefs()
    }
}
