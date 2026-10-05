# Streaming Client for macOS and iOS — Build Plan

Oct 2, 2026

## Overview

Build one native multiplatform SwiftUI app for Mac and iPhone that browses and streams via Stremio addons, and can save titles for offline viewing in a "Saved" library with posters and metadata.

**Key decisions**

- **Native Swift, not a Stremio fork.** Stremio's download/streaming server is closed source, and offline-first is easier natively.
- **One multiplatform target, shared core.** Addon client, models, downloads and library code are shared; only views and a few platform services differ.
- **Stremio addon protocol for everything.** Catalogs (Cinemeta, TMDB) for browsing; Comet/MediaFusion for streams. Any addon works by pasting its manifest URL.
- **Debrid is handled by the addons.** The TorBox key lives inside the configured Comet manifest URL. The app never calls TorBox directly in v1.
- **Offline library = folder + sidecar `meta.json` per title.** Images are stored locally; the library needs no network on either platform.
- **Personal use, installed with your developer account.** iPhone builds go on via Xcode (1-year provisioning) or TestFlight; no App Store submission.

**In scope for v1:** addon management, browse/search, title detail, stream list, playback, download, Saved library, resume progress.

**Out of scope for v1:** raw torrent playback, Stremio account sync, tvOS, iPad-specific layouts, App Store distribution, subtitles download (stretch goal).

## Tech stack and project structure

Swift 6, SwiftUI, one multiplatform Xcode target for macOS 14+ and iOS 17+, no third-party dependencies except the player.

| Concern | Shared | macOS | iOS |
| --- | --- | --- | --- |
| UI | SwiftUI views where possible | `NavigationSplitView`, separate player window | `TabView` + `NavigationStack`, full-screen player |
| Networking | `URLSession` + async/await, `Codable` | — | — |
| Playback | AVPlayer first; MPVKit (libmpv) for MKV/HEVC | Keyboard shortcuts | Landscape, PiP, `AVAudioSession` playback category |
| Downloads | `DownloadManager` with resume data | Foreground `URLSession` | Background `URLSession` (continues when suspended) |
| Library location | Sidecar JSON per title, relative paths | `~/Movies/<AppName>/`, user-configurable | Application Support, excluded from iCloud backup |
| Persistence | JSON or SwiftData for settings and addon list | — | — |
| Secrets | Keychain (addon URLs contain the TorBox key) | — | — |
| Folder watching | — | FSEvents | Not needed (only the app writes) |

```
App/
  App.swift
  Features/          shared SwiftUI views
    Browse/          catalog grid, search
    Detail/          meta, seasons/episodes, stream list
    Player/          player view + controller
    Library/         Saved grid, offline detail
    Downloads/       queue UI
    Settings/        addons, download folder, storage
  Core/              no UI, no platform #if where avoidable
    Addons/          Manifest, AddonClient, AddonRegistry
    Models/          MetaPreview, MetaDetail, Video, Stream
    Downloads/       DownloadManager
    Library/         LibraryStore, SidecarMeta, LibraryLocation
    Storage/         Keychain, Settings
  Platform/
    macOS/           window/menu commands, FSEvents watcher
    iOS/             AppDelegate for background URLSession, audio session, PiP
Tests/
```

AVPlayer cannot play MKV, which many streams use, on either platform. MPVKit is added in M3 and supports both macOS and iOS; until then, filter streams to MP4.

## Architecture

&#91;embedded content: app architecture · online, app and on-disk parts\]

AddonRegistry is the only part that talks to addons, DownloadManager the only part that writes to the library folder, and LibraryStore plus Player need nothing online.

**Browse flow:** catalog addon → `MetaPreview` grid → meta addon → `MetaDetail` with episodes → all stream addons → merged `Stream` list → play or save.

**Save flow:** tap Save on a stream → DownloadManager writes poster, backdrop and `meta.json` → downloads the video from the addon URL (redirects to TorBox) → marks the item complete in `meta.json` → LibraryStore picks up the change and it appears in Saved.

## Data models and library format

Models mirror the Stremio addon protocol so addon JSON decodes directly.

| Model | Key fields |
| --- | --- |
| `Manifest` | `id`, `name`, `version`, `resources` (string or object), `types`, `catalogs`, `idPrefixes` |
| `MetaPreview` | `id`, `type`, `name`, `poster`, `posterShape` |
| `MetaDetail` | preview fields + `background`, `logo`, `description`, `releaseInfo`, `genres`, `videos` |
| `Video` | `id` (`tt…:season:episode`), `title`, `season`, `episode`, `released`, `thumbnail` |
| `Stream` | `url`, `infoHash`, `fileIdx`, `name`, `title`, `description`, `behaviorHints` (`filename`, `notWebReady`, `bingeGroup`, `proxyHeaders`) |
| `Addon` | `manifestURL` (secret), `manifest`, `enabled`, `order` |

**Library folder:** on macOS `~/Movies/<AppName>/` (user-configurable); on iOS `Application Support/Library/` with `isExcludedFromBackup = true`. A `LibraryLocation` type resolves the root per platform; everything below it is identical:

```
<library>/
  tt0111161/
    meta.json
    poster.jpg
    backdrop.jpg
    The.Shawshank.Redemption.1994.mkv
  tt0903747/
    meta.json
    poster.jpg
    S01E01.mkv
```

**`meta.json`**

```json
{
  "schemaVersion": 1,
  "id": "tt0903747",
  "type": "series",
  "name": "Breaking Bad",
  "year": "2008",
  "description": "...",
  "genres": ["Drama"],
  "poster": "poster.jpg",
  "backdrop": "backdrop.jpg",
  "items": [
    {
      "videoId": "tt0903747:1:1",
      "season": 1,
      "episode": 1,
      "title": "Pilot",
      "file": "S01E01.mkv",
      "sizeBytes": 1234567890,
      "savedAt": "2026-10-02T12:00:00Z",
      "progressSeconds": 1834,
      "durationSeconds": 3480
    }
  ]
}
```

Movies use one entry in `items` with no season/episode. Write `meta.json` atomically (temp file + rename) so a crash never corrupts it. Store only paths relative to the title folder: the iOS app container path changes between installs and updates, so absolute paths break.

## Milestones

Each milestone ends with a working, runnable app. Give Claude Code one milestone at a time. From M1 on, every milestone must build for both macOS and iOS; M2–M5 focus on the Mac UI, and M6 makes the iPhone UI first-class.

**M1 — Addon core**

- [ ] Create Xcode project / SwiftPM layout per the structure above
- [x] `Manifest`, `MetaPreview`, `MetaDetail`, `Video`, `Stream` models with decoding tests using real addon JSON fixtures
- [x] `AddonClient`: manifest, catalog (with `search=` and `skip=` extras), meta, stream
- [x] `AddonRegistry`: add/remove/reorder addons, persist URLs in Keychain, pick addons per resource/type/idPrefix
- [x] Settings screen to paste a manifest URL

Done when: Cinemeta and Comet can be added and their manifests show in Settings.

**M2 — Browse and detail**

- [x] Home: rows per catalog (movie/series), poster grid, paging
- [x] Search across all addons with a search catalog
- [x] Detail view: backdrop, description, seasons/episodes picker
- [x] Stream list: query all stream addons in parallel, merge, show addon name + stream title, cached-first sorting

Done when: you can find a show, open an episode, and see Comet streams.

**M3 — Playback**

- [x] Player window with AVPlayer, play/pause, seek, fullscreen, keyboard shortcuts
- [x] Save watch progress every 10 s and on close; resume prompt
- [x] Integrate libmpv (MPVKit) for MKV/HEVC and embedded subtitles; fall back to AVPlayer for MP4

Done when: a Comet stream plays and resumes where you left off.

**M4 — Downloads**

- [ ] "Save to computer" / "Download" button on each stream
- [x] `DownloadManager`: queue, progress, pause/resume, cancel, max concurrent downloads (setting)
- [x] Design it around delegate callbacks (not async `download(from:)`), so the same code works with an iOS background session in M6
- [x] On pause/failure keep resume data; if resume fails, re-request the addon URL for a fresh link
- [x] Filename from `behaviorHints.filename`, then `suggestedFilename`, then a generated `S01E01.ext`
- [x] On start: download poster/backdrop and write `meta.json`; on finish: add the item
- [x] Downloads screen with progress; persist queue across app restarts

Done when: an episode downloads, survives an app restart mid-download, and lands in the library folder with `meta.json`.

**M5 — Saved library (offline)**

- [x] `LibraryStore`: scan library folder, decode sidecars, watch folder for changes (FSEvents, macOS only)
- [ ] "Saved movies/shows" sidebar section with local posters
- [x] Offline detail view: saved episodes only, progress bars, play local file
- [x] Delete saved item (permanent delete after confirmation, updates `meta.json`, removes empty title folder)
- [x] Offline mode: detect no network, hide online sections, open straight to Saved

Done when: with Wi-Fi off, the app opens, shows Saved with posters, and plays a file.

**M6 — iPhone**

- [x] iOS navigation: `TabView` with Home, Search, Saved, Downloads, Settings; `NavigationStack` per tab
- [ ] Full-screen player: landscape, Picture in Picture, `AVAudioSession` `.playback` so audio continues when locked
- [x] Background downloads: background `URLSessionConfiguration` with a fixed identifier, handle `handleEventsForBackgroundURLSession`, reattach to running tasks on launch, move the file inside `didFinishDownloadingTo` before returning
- [ ] "Download on Wi-Fi only" setting (`allowsCellularAccess`)
- [ ] Storage: free-space check before each download, Storage screen with per-title size and delete
- [ ] Exclude the library folder from iCloud backup
- [ ] Install on your iPhone from Xcode with your developer account; optionally set up TestFlight for easier updates

Done when: on the iPhone, a download keeps going with the app in the background, and in airplane mode Saved shows posters and plays the episode.

**M7 — Polish (stretch)**

- [ ] Import files dropped manually into the folder (Mac) or added via the Files app (iPhone): parse filename, match via Cinemeta when online, write sidecar
- [x] Subtitles addon support (OpenSubtitles), saved alongside downloads
- [x] Default addons (Cinemeta, Streaming Catalogs, OpenSubtitles v3) + "Recommended" section in Addon settings
- [x] Discover: browse catalogs by type/genre (catalog `extra` support), sidebar item on macOS, tab on iOS; search dedupe/grouping
- [x] Stream quality filter (4K/1080p/720p/SD) remembered across titles, used by Play/Download buttons
- [x] Default audio/subtitle language + subtitle mode in Settings, applied in mpv and AVPlayer
- [ ] Continue Watching row
- [ ] Auto-play next episode (`bingeGroup`)

**Suggestions (For You)**

- [x] `Recommendations` engine: seeds from Stremio library + local progress (recency × completion), excludes watched/dismissed titles, per-source disk cache, stale feed shown while refreshing
- [x] Cinemeta source (no key): "Top Picks for You" + top genre rows from the seeds' genres
- [x] TMDB source: optional key in Keychain (validated on save, never logged), "Because you watched" rows mapped back to IMDb ids, falls back to Cinemeta with an inline notice
- [x] For You page: header with seed strip + TMDB/Cinemeta switcher (locked without a key), hero pick, rows, "Not Interested" context menu, loading / no-history / failed states, TMDB upsell and attribution
- [x] Settings: Suggestions card (connect/manage TMDB, reset "Not Interested" titles)
- [x] Home: "Suggested for You" row under Latest (on by default, toggle in Customize Home); billboard shows 6 random suggestions, falling back to the first catalog without history
- [x] Shell: "For You" after Home in the macOS sidebar (⌘2) and on iOS; iPhone groups Library, Saved, Downloads and Settings in a "Library" hub tab so nothing overflows into "More"; iPad uses the adaptable sidebar

## Edge cases, security and open questions

**Edge cases**

- Uncached torrents: the Comet URL may return an error or placeholder video. Prefer cached streams; show a clear error if a download returns non-video content (check `Content-Type` and size).
- Expired links: debrid links expire. Re-resolve through the addon URL on resume failure.
- Disk space: check free space against `Content-Length` before starting; on iPhone use `volumeAvailableCapacityForImportantUsage`.
- Duplicate saves: same `videoId` already saved → offer replace or keep both.
- Library on an external drive that is unplugged (Mac): show Saved as unavailable instead of empty.
- Addons that are down or slow: per-addon timeout (\~10 s), show results from the rest.
- iOS background downloads: the system may delay or throttle them (Low Power Mode, poor network); show "waiting" state rather than failing.
- iOS app killed by the user from the app switcher cancels background downloads; keep resume data so they can continue on next launch.

**Security**

- Configured addon URLs contain the TorBox key. Store them in the Keychain, never log full URLs, and redact them in error messages.
- Add `*.local`, test fixtures and any config with URLs to `.gitignore`.
- Treat addon responses as untrusted input: validate URLs are http(s) before playing or downloading.

**Open questions**

- App name and bundle ID.
- Minimum versions (macOS 14 and iOS 17 assumed).
- Default library folder: `~/Movies/<AppName>` or user picks on first launch.
- iPhone updates: reinstall from Xcode each time, or use TestFlight?

## Using this plan with Claude Code

Export this doc as Markdown, save it in the repo as `PLAN.md`, and add a short `CLAUDE.md` so every session has the context.

**`CLAUDE.md`**

```markdown
# Project
Native multiplatform streaming client (SwiftUI, macOS 14+ and iOS 17+) using the Stremio addon protocol.
Full plan: PLAN.md. Work one milestone at a time; tick tasks off in PLAN.md when done.

# Rules
- Swift 6, SwiftUI, async/await, Codable. No third-party deps except MPVKit.
- One multiplatform target. Core/ has no UI and avoids #if os(); platform code lives in Platform/.
- Every change must build for both macOS and iOS.
- Keep code clean; only comment where something is genuinely non-obvious.
- Never commit or push unless explicitly asked.
- Addon manifest URLs contain secrets: Keychain only, never log or hardcode them.
- Library paths in meta.json are relative to the title folder, never absolute.
- Add tests for decoding and LibraryStore; use JSON fixtures in Tests/Fixtures.

# Build
xcodebuild -scheme <AppName> -destination 'platform=macOS' build test
xcodebuild -scheme <AppName> -destination 'generic/platform=iOS Simulator' build
```

**First prompts**

1. "Read PLAN.md and CLAUDE.md. Set up a multiplatform project (macOS + iOS) with the structure from the plan and confirm it builds for both. Don't implement features yet."
2. "Implement M1. Start with the models and decoding tests using fixtures from Cinemeta and a sample stream response, then AddonClient, AddonRegistry and the Settings screen."
3. After each milestone: "Run the build and tests, fix failures, then summarize what's done and what's left in M\<n>."

Tip: fetch real fixtures once with `curl https://v3-cinemeta.strem.io/manifest.json` and `.../catalog/movie/top.json`, so tests don't depend on the network. Keep your configured Comet URL out of fixtures.
