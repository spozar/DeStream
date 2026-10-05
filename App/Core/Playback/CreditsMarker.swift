import Foundation

/// Where the end credits of an episode start, for the "Up Next" prompt.
enum CreditsMarker {
    /// Episodes shorter than this (trailers, shorts) never get the prompt before the end.
    static let minimumDuration: Double = 5 * 60

    /// The first credits-like chapter in the second half of the file, else a fixed lead before the end
    /// (3.5% of the runtime, clamped to 30 s – 2 min: ~45 s for a sitcom, ~1.5–2 min for an hour-long drama).
    static func start(duration: Double?, chapters: [PlayerChapter]) -> Double? {
        guard let duration, duration.isFinite, duration >= minimumDuration else { return nil }
        if let chapter = chapters.first(where: { $0.time > duration / 2 && $0.time < duration && isCredits($0.title) }) {
            return chapter.time
        }
        return duration - fallbackLead(duration: duration)
    }

    static func fallbackLead(duration: Double) -> Double {
        min(120, max(30, duration * 0.035))
    }

    static func isCredits(_ title: String?) -> Bool {
        guard let title = title?.lowercased().trimmingCharacters(in: .whitespaces), !title.isEmpty else { return false }
        if ["ed", "end", "ending", "outro", "credits", "closing"].contains(title) { return true }
        return title.range(of: #"\b(credits?|ending|outro|closing)\b|\bend\s*(credits|title|song)\b"#,
                           options: .regularExpression) != nil
    }
}
