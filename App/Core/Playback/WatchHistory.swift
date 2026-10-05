import Foundation

/// Series watch-history helpers built on `ProgressStore`. OWNER: UI Agent 6.
extension ProgressStore {
    /// True when the entry counts as "in progress" for resuming (started, not finished).
    nonisolated static func isInProgress(_ entry: Entry) -> Bool {
        guard !entry.isFinished else { return false }
        if entry.duration == nil { return entry.seconds >= minimumResumeSeconds }
        return entry.isStarted
    }

    /// Episode to offer on a series' Play button:
    /// the most recently played episode if it's still in progress; otherwise the episode after the
    /// furthest watched one (season/episode order, specials ignored); otherwise the first episode.
    /// When every episode is watched it starts over at the first. Nil for metas without episodes.
    func nextUp(for meta: MetaDetail) -> Video? {
        let episodes = Self.orderedEpisodes(meta)
        guard !episodes.isEmpty else { return nil }
        let ids = Set(episodes.map(\.id))
        let history = entries.values.filter { ids.contains($0.videoId) }

        let latest = history
            .filter { Self.isInProgress($0) || $0.isFinished }
            .max { $0.updatedAt < $1.updatedAt }
        if let latest, Self.isInProgress(latest), let video = episodes.first(where: { $0.id == latest.videoId }) {
            return video
        }

        let watched = Set(history.filter(\.isFinished).map(\.videoId))
        if let last = episodes.lastIndex(where: { watched.contains($0.id) }) {
            let next = episodes.index(after: last)
            return next < episodes.endIndex ? episodes[next] : episodes.first
        }
        return episodes.first
    }

    /// Regular episodes (season > 0) in season/episode order; specials only when a meta has nothing else.
    nonisolated static func orderedEpisodes(_ meta: MetaDetail) -> [Video] {
        let all = (meta.videos ?? []).filter { $0.season != nil && $0.episode != nil }
        let regular = all.filter { ($0.season ?? 0) > 0 }
        return (regular.isEmpty ? all : regular).sorted { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) }
    }
}
