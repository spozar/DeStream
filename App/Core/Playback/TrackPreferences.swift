import Foundation

/// When subtitles are turned on automatically at playback start.
enum SubtitleMode: String, CaseIterable, Sendable {
    case off
    /// Full subtitles only when the audio isn't in one of the subtitle languages; otherwise forced subtitles only.
    case foreignAudio
    case always

    var title: String {
        switch self {
        case .off: "Off"
        case .foreignAudio: "Foreign audio only"
        case .always: "Always"
        }
    }
}

/// The user's default audio/subtitle languages (canonical ISO 639-1 codes) applied when a video starts.
struct TrackPreferences: Hashable, Sendable {
    /// nil keeps the file's default (original) audio.
    var audioLanguage: String?
    var subtitleMode: SubtitleMode = .off
    /// Preferred first; later entries are fallbacks.
    var subtitleLanguages: [String] = []

    /// mpv `alang` value, e.g. "swe,sv"; empty for the file's default.
    var mpvAudioLanguages: String {
        audioLanguage.map { LanguageCodes.variants(of: $0).joined(separator: ",") } ?? ""
    }

    var mpvSubtitleLanguages: String {
        subtitleLanguages.flatMap(LanguageCodes.variants(of:)).joined(separator: ",")
    }

    func preferredAudio(in tracks: [PlayerTrack]) -> PlayerTrack? {
        guard let wanted = LanguageCodes.canonical(audioLanguage) else { return nil }
        let matches = tracks.filter { $0.kind == .audio && LanguageCodes.language(of: $0) == wanted }
        return matches.first(where: \.isDefault) ?? matches.first
    }

    /// The subtitle to show with `audio`, or nil for none. Embedded tracks win over external ones.
    func preferredSubtitle(in tracks: [PlayerTrack], audio: PlayerTrack?) -> PlayerTrack? {
        let subs = tracks.filter { $0.kind == .subtitle }
        let languages = subtitleLanguages.compactMap(LanguageCodes.canonical)
        switch subtitleMode {
        case .off:
            return nil
        case .foreignAudio:
            guard let audioLanguage = audio.flatMap(LanguageCodes.language(of:)) else { return nil }
            if languages.contains(audioLanguage) {
                return subs.first { $0.looksForced && LanguageCodes.language(of: $0) == audioLanguage }
            }
        case .always:
            break
        }
        for language in languages {
            let full = subs.filter { !$0.looksForced && LanguageCodes.language(of: $0) == language }
            if let best = full.first(where: { !$0.isExternal && $0.isDefault }) ?? full.first(where: { !$0.isExternal }) ?? full.first {
                return best
            }
        }
        return nil
    }
}

extension PlayerTrack {
    /// Many files only mark forced subtitles in the track title.
    var looksForced: Bool { isForced || (title?.localizedCaseInsensitiveContains("forced") ?? false) }
}

/// Applies `TrackPreferences` once tracks are known, until the user picks a track themselves.
struct TrackAutoSelection {
    var preferences = TrackPreferences()
    var audioLocked = false
    var subtitleLocked = false

    mutating func reset() {
        audioLocked = false
        subtitleLocked = false
    }

    /// Changes to apply: `audio` nil = keep; `subtitle` nil = keep, `.some(nil)` = turn off.
    mutating func resolve(audio: [PlayerTrack], subtitles: [PlayerTrack],
                          selectedAudio: Int?, selectedSubtitle: Int?) -> (audio: Int?, subtitle: Int??) {
        var audioChange: Int?
        var audioID = selectedAudio
        if !audioLocked, !audio.isEmpty {
            audioLocked = true
            if let track = preferences.preferredAudio(in: audio), track.id != selectedAudio {
                audioChange = track.id
                audioID = track.id
            }
        }
        guard !subtitleLocked else { return (audioChange, nil) }
        let audioTrack = audio.first { $0.id == audioID } ?? (audio.count == 1 ? audio.first : nil)
        let target = preferences.preferredSubtitle(in: subtitles, audio: audioTrack)?.id
        return (audioChange, target != selectedSubtitle ? .some(target) : nil)
    }
}

/// A subtitle file served by an addon's `subtitles` resource, or saved next to a downloaded video.
struct ExternalSubtitle: Hashable, Sendable {
    var url: URL
    var language: String?
    var source: String?
    /// The addon's original file name, used for the saved file's extension.
    var fileName: String? = nil
    /// The addon matched it by video hash, so it is synced to this exact release.
    var isHashMatch: Bool = false
}

/// Normalizes the language tags found in containers, HLS and addons ("swe", "sv", "sv-SE", "ger", "pob").
enum LanguageCodes {
    /// Canonical code → other spellings seen in the wild (ISO 639-2/T and /B, OpenSubtitles codes).
    private static let table: [String: [String]] = [
        "en": ["eng"], "sv": ["swe"], "da": ["dan"], "no": ["nor", "nob", "nno", "nb", "nn"], "fi": ["fin"],
        "is": ["isl", "ice"], "de": ["deu", "ger"], "fr": ["fra", "fre"], "es": ["spa", "spn", "ea"],
        "it": ["ita"], "pt": ["por", "pob", "pb"], "nl": ["nld", "dut"], "pl": ["pol"], "cs": ["ces", "cze"],
        "sk": ["slk", "slo"], "hu": ["hun"], "ro": ["ron", "rum"], "bg": ["bul"], "hr": ["hrv"],
        "sr": ["srp", "scc"], "sl": ["slv"], "el": ["ell", "gre"], "tr": ["tur"], "ru": ["rus"], "uk": ["ukr"],
        "et": ["est"], "lv": ["lav"], "lt": ["lit"], "ar": ["ara"], "he": ["heb"], "fa": ["fas", "per"],
        "hi": ["hin"], "th": ["tha"], "vi": ["vie"], "id": ["ind"], "ms": ["msa", "may"],
        "zh": ["zho", "chi", "zht", "zhe", "chs", "cht"], "ja": ["jpn"], "ko": ["kor"],
    ]

    private static let aliases: [String: String] = {
        var map: [String: String] = [:]
        for (code, variants) in table {
            map[code] = code
            for v in variants { map[v] = code }
        }
        return map
    }()

    /// Languages offered in Settings.
    static var common: [String] { Array(table.keys) }

    /// Lowercased ISO 639-1 code where known; nil for empty or "undetermined" tags.
    static func canonical(_ tag: String?) -> String? {
        guard var code = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !code.isEmpty else { return nil }
        if let cut = code.firstIndex(where: { $0 == "-" || $0 == "_" }) { code = String(code[..<cut]) }
        if ["und", "unk", "mul", "zxx", "mis", "none"].contains(code) { return nil }
        return aliases[code] ?? code
    }

    /// Every spelling of a language, for matching against container tags (mpv `alang`/`slang`).
    static func variants(of code: String) -> [String] {
        guard let canonical = canonical(code) else { return [] }
        return [canonical] + (table[canonical] ?? [])
    }

    /// A track's language from its tag, or from a title like "English" when the tag is missing.
    static func language(of track: PlayerTrack) -> String? {
        if let code = canonical(track.language) { return code }
        guard let title = track.title?.lowercased(), !title.isEmpty else { return nil }
        let english = Locale(identifier: "en")
        return table.keys.first { code in
            [english.localizedString(forLanguageCode: code), Locale.current.localizedString(forLanguageCode: code)]
                .compactMap { $0?.lowercased() }
                .contains { title.hasPrefix($0) }
        }
    }

    static func displayName(_ tag: String) -> String {
        let code = canonical(tag) ?? tag
        guard let name = Locale.current.localizedString(forLanguageCode: code) else { return tag.uppercased() }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Fetches subtitles from installed addons that serve the `subtitles` resource (e.g. OpenSubtitles).
enum AddonSubtitles {
    @MainActor
    static func fetch(registry: AddonRegistry, type: String, id: String, languages: [String],
                      fingerprint: VideoFingerprint? = nil, perLanguage: Int = 2) async -> [ExternalSubtitle] {
        let addons = registry.addons(for: "subtitles", type: type, id: id)
        return await fetch(addons: addons, type: type, id: id, languages: languages,
                           fingerprint: fingerprint, perLanguage: perLanguage).subtitles
    }

    /// `answered` is false when no addon returned a valid response (e.g. offline).
    static func fetch(addons: [Addon], type: String, id: String, languages: [String],
                      fingerprint: VideoFingerprint?, perLanguage: Int = 2) async -> (subtitles: [ExternalSubtitle], answered: Bool) {
        guard !addons.isEmpty, !languages.isEmpty else { return ([], false) }
        let results = await withTaskGroup(of: (Int, [ExternalSubtitle]?).self) { group in
            for (i, addon) in addons.enumerated() {
                group.addTask { (i, await fetch(addon, type: type, id: id, fingerprint: fingerprint)) }
            }
            var out: [Int: [ExternalSubtitle]] = [:]
            for await (i, subs) in group { out[i] = subs }
            return out
        }
        let all = addons.indices.flatMap { results[$0] ?? [] }
        return (pick(all, languages: languages, perLanguage: perLanguage), !results.isEmpty)
    }

    /// Up to `perLanguage` subtitles per wanted language, in language-preference order, hash matches first, without duplicates.
    static func pick(_ subtitles: [ExternalSubtitle], languages: [String], perLanguage: Int) -> [ExternalSubtitle] {
        var seen = Set<URL>()
        var result: [ExternalSubtitle] = []
        for language in languages.compactMap(LanguageCodes.canonical) {
            let matches = subtitles.filter { LanguageCodes.canonical($0.language) == language && !seen.contains($0.url) }
            let ordered = matches.filter(\.isHashMatch) + matches.filter { !$0.isHashMatch }
            for sub in ordered.prefix(perLanguage) {
                seen.insert(sub.url)
                result.append(sub)
            }
        }
        return result
    }

    /// `{base}/subtitles/{type}/{id}/videoHash=…&videoSize=…&filename=….json`, or without extras when nothing is known.
    static func requestURL(base: URL, type: String, id: String, fingerprint: VideoFingerprint?) -> URL? {
        AddonClient.resourceURL(base: base, resource: "subtitles", type: type, id: id, extras: fingerprint?.extras ?? [])
    }

    /// nil when the addon couldn't be reached or answered with garbage.
    private static func fetch(_ addon: Addon, type: String, id: String, fingerprint: VideoFingerprint?) async -> [ExternalSubtitle]? {
        guard let base = addon.baseURL else { return nil }
        if fingerprint?.extras.isEmpty == false,
           let url = requestURL(base: base, type: type, id: id, fingerprint: fingerprint),
           let subs = await fetch(url, addon: addon) {
            return subs
        }
        guard let url = requestURL(base: base, type: type, id: id, fingerprint: nil) else { return nil }
        return await fetch(url, addon: addon)
    }

    private static func fetch(_ url: URL, addon: Addon) async -> [ExternalSubtitle]? {
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let decoded = try? AddonClient.decode(SubtitlesResponse.self, from: data, label: addon.redactedURL)
        else { return nil }
        return decoded.subtitles.compactMap { entry in
            guard let string = entry.url, let url = URL(string: string),
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return ExternalSubtitle(url: url, language: entry.lang, source: addon.manifest.name,
                                    fileName: entry.subtitleFileName, isHashMatch: entry.m == "h")
        }
    }
}

struct SubtitlesResponse: Decodable {
    struct Entry: Decodable {
        var url: String?
        var lang: String?
        /// OpenSubtitles v3: "h" = matched by video hash, "i" = by IMDb id only.
        var m: String?
        var subtitleFileName: String?

        private enum CodingKeys: String, CodingKey { case url, lang, m, subtitleFileName }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            lang = try? c.decodeIfPresent(String.self, forKey: .lang)
            m = try? c.decodeIfPresent(String.self, forKey: .m)
            subtitleFileName = try? c.decodeIfPresent(String.self, forKey: .subtitleFileName)
        }
    }
    var subtitles: [Entry]

    private enum CodingKeys: String, CodingKey { case subtitles }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = (try? c.decodeIfPresent([Entry].self, forKey: .subtitles)) ?? []
    }
}
