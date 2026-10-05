# Releasing

Releases are published on this repository's [Releases](https://github.com/spozar/DeStream/releases) page, with a notarized `.dmg` and `.zip` attached.

## Cutting one

Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.yml`, commit, and push to `main`:

```bash
git commit -am "DeStream 0.3.0"
git push origin main
```

`.github/workflows/release.yml` sees that `v0.3.0` has no tag yet, builds on a macOS runner, signs with Developer ID, notarizes and staples the app and the disk image, and publishes `v0.3.0`. Pushes that leave the version alone stop after a few seconds. It can also be started from **Actions → Release → Run workflow**.

Release notes come from a `## 0.3.0` section in `CHANGELOG.md` if there is one, otherwise GitHub lists the commits since the last release.

## Secrets

Under **Settings → Secrets and variables → Actions**. Without them the workflow publishes nothing and warns instead.

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | the Developer ID Application certificate + private key exported as `.p12`, base64 encoded |
| `MACOS_CERTIFICATE_PASSWORD` | the password given to that `.p12` |
| `NOTARY_APPLE_ID` | the Apple ID used for notarization |
| `NOTARY_TEAM_ID` | `99476Z45K6` |
| `NOTARY_PASSWORD` | an app-specific password for that Apple ID (appleid.apple.com → Sign-In and Security) |
| `MACOS_SIGNING_IDENTITY` | optional; defaults to `Developer ID Application: Mediaempire Group AB (99476Z45K6)` |

## Locally

```bash
NOTARY_PROFILE=notary scripts/dmg-mac.sh     # → dist/DeStream-<version>.zip and .dmg
```
