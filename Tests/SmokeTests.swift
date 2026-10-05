import XCTest
@testable import DeStream

final class SmokeTests: XCTestCase {
    func testFixturesBundled() throws {
        let url = Bundle(for: Self.self).url(forResource: "Fixtures/cinemeta_manifest", withExtension: "json")
            ?? Bundle(for: Self.self).url(forResource: "cinemeta_manifest", withExtension: "json")
        XCTAssertNotNil(url)
    }
}

final class TrackPreferencesTests: XCTestCase {
    private func audio(_ id: Int, _ lang: String?, isDefault: Bool = false) -> PlayerTrack {
        PlayerTrack(id: id, kind: .audio, language: lang, isDefault: isDefault)
    }

    private func sub(_ id: Int, _ lang: String?, title: String? = nil, forced: Bool = false, external: Bool = false) -> PlayerTrack {
        PlayerTrack(id: id, kind: .subtitle, title: title, language: lang, isForced: forced, isExternal: external)
    }

    func testLanguageCodesNormalize() {
        XCTAssertEqual(LanguageCodes.canonical("swe"), "sv")
        XCTAssertEqual(LanguageCodes.canonical("sv-SE"), "sv")
        XCTAssertEqual(LanguageCodes.canonical("ger"), "de")
        XCTAssertEqual(LanguageCodes.canonical("pob"), "pt")
        XCTAssertEqual(LanguageCodes.canonical("NOB"), "no")
        XCTAssertNil(LanguageCodes.canonical("und"))
        XCTAssertNil(LanguageCodes.canonical(""))
        XCTAssertEqual(LanguageCodes.variants(of: "de"), ["de", "deu", "ger"])
        XCTAssertEqual(TrackPreferences(audioLanguage: "sv").mpvAudioLanguages, "sv,swe")
        XCTAssertEqual(LanguageCodes.language(of: sub(1, nil, title: "English (SDH)")), "en")
    }

    func testAudioPreference() {
        let tracks = [audio(1, "eng", isDefault: true), audio(2, "swe")]
        XCTAssertEqual(TrackPreferences(audioLanguage: "sv").preferredAudio(in: tracks)?.id, 2)
        XCTAssertNil(TrackPreferences(audioLanguage: "fr").preferredAudio(in: tracks))
        XCTAssertNil(TrackPreferences().preferredAudio(in: tracks))
    }

    func testSubtitleModes() {
        let subs = [sub(1, "eng", forced: true), sub(2, "eng"), sub(3, "swe", external: true), sub(4, "swe")]
        let english = audio(1, "en"), japanese = audio(2, "jpn")
        var prefs = TrackPreferences(subtitleMode: .off, subtitleLanguages: ["sv", "en"])
        XCTAssertNil(prefs.preferredSubtitle(in: subs, audio: japanese))

        prefs.subtitleMode = .always
        XCTAssertEqual(prefs.preferredSubtitle(in: subs, audio: english)?.id, 4, "embedded wins over external")

        prefs.subtitleMode = .foreignAudio
        prefs.subtitleLanguages = ["en"]
        XCTAssertEqual(prefs.preferredSubtitle(in: subs, audio: english)?.id, 1, "forced only when audio is understood")
        XCTAssertEqual(prefs.preferredSubtitle(in: subs, audio: japanese)?.id, 2)
        XCTAssertNil(prefs.preferredSubtitle(in: subs, audio: nil))

        prefs.subtitleLanguages = ["fr", "sv"]
        XCTAssertEqual(prefs.preferredSubtitle(in: subs, audio: japanese)?.id, 4, "falls back to the second language")
    }

    func testAutoSelectionRespectsManualChoice() {
        var selection = TrackAutoSelection(preferences: TrackPreferences(audioLanguage: "sv", subtitleMode: .foreignAudio, subtitleLanguages: ["sv"]))
        let audios = [audio(1, "eng"), audio(2, "swe")]
        let subs = [sub(3, "swe")]
        var change = selection.resolve(audio: audios, subtitles: subs, selectedAudio: 1, selectedSubtitle: nil)
        XCTAssertEqual(change.audio, 2)
        XCTAssertNil(change.subtitle, "Swedish audio needs no Swedish subtitles")

        // User switches to English audio: subtitles follow.
        selection.audioLocked = true
        change = selection.resolve(audio: audios, subtitles: subs, selectedAudio: 1, selectedSubtitle: nil)
        XCTAssertNil(change.audio)
        XCTAssertEqual(change.subtitle, .some(3))

        selection.subtitleLocked = true
        change = selection.resolve(audio: audios, subtitles: subs, selectedAudio: 2, selectedSubtitle: 3)
        XCTAssertNil(change.audio)
        XCTAssertNil(change.subtitle)
    }

    func testAddonSubtitlePickAndDecode() throws {
        let json = #"{"subtitles":[{"id":"1","url":"https://s/1.srt","lang":"eng"},{"id":"2","url":"https://s/2.srt","lang":"swe"},{"id":"3","url":"https://s/3.srt","lang":"eng"},{"id":"4","url":"https://s/4.srt","lang":"eng"},{"id":"5","lang":"swe"}]}"#
        let decoded = try AddonClient.decode(SubtitlesResponse.self, from: Data(json.utf8), label: "test")
        XCTAssertEqual(decoded.subtitles.count, 5)
        let all = decoded.subtitles.compactMap { e in e.url.flatMap(URL.init(string:)).map { ExternalSubtitle(url: $0, language: e.lang) } }
        let picked = AddonSubtitles.pick(all, languages: ["sv", "en"], perLanguage: 2)
        XCTAssertEqual(picked.map(\.url.lastPathComponent), ["2.srt", "1.srt", "3.srt"])
    }
}
