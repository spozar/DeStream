# DeStream

A native streaming client for macOS and iPhone, built with SwiftUI on the [Stremio addon protocol](https://github.com/Stremio/stremio-addon-sdk). Browse catalogs, pick a stream from your addons, play it with mpv, and save titles for offline viewing.

## Download

Get the latest `.dmg` (or `.zip`) from [Releases](https://github.com/spozar/DeStream/releases/latest). It is signed with Developer ID and notarized, so it opens with a double-click. Requires macOS 14 or later.

DeStream ships no content and no addons: you add your own by pasting their manifest URLs. Addon URLs can contain API keys, so they are stored only in the Keychain.

## Building

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
scripts/build.sh dev mac     # or ios, test, all
```

See [RELEASING.md](RELEASING.md) for cutting a release.
