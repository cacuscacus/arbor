# Releases

How Arbor ships builds, how users update, and how maintainers cut a release.

**Policy:** Arbor does **not** use an Apple Developer Program membership (no Developer ID signing, no notarization). Distribution and updates are built around **GitHub Releases** + **Homebrew**, with an optional lightweight in-app check against the GitHub API. **Sparkle is not used** — it can run without Apple signing, but Gatekeeper still blocks or warns on unsigned apps, so auto-replace adds complexity without a smooth UX.

Repository: https://github.com/cacuscacus/arbor  
Releases: https://github.com/cacuscacus/arbor/releases

---

## Channels

| Channel | Role | How users get updates |
|---------|------|------------------------|
| **GitHub Releases** | Source of truth for versions and downloadable assets | Download the latest asset from the release page |
| **Homebrew cask** | **Preferred** install and upgrade path on macOS | `brew upgrade --cask arbor` |
| **In-app “Check for Updates…”** | Awareness only (planned) | Compare local version to latest release; open GitHub or show the brew command — does **not** replace the `.app` automatically |

```
git tag vX.Y.Z ──► GitHub Release ──► DMG/ZIP asset
                         │                  │
                         │                  ├──► Homebrew cask
                         │                  └──► Direct download
                         │
                         └──► Releases API ──► Check for Updates… menu
```

### Why Homebrew is preferred

Without notarization, macOS Gatekeeper treats direct downloads as untrusted. Users may need to right-click → **Open** (or clear quarantine) the first time. Homebrew’s install flow is more familiar for developers and is the default we document for end users.

---

## Versioning

Use [Semantic Versioning](https://semver.org/).

| Field | Where | Example |
|-------|--------|---------|
| Marketing version | Xcode `MARKETING_VERSION` in `apps/macos/Arbor.xcodeproj/project.pbxproj` | `0.1.0` |
| Build number | Xcode `CURRENT_PROJECT_VERSION` | `1`, then `2`, … (bump every release) |
| Git tag | Annotated tag on `main` | `v0.1.0` |
| Release title | GitHub Release | `v0.1.0` |
| Crate version | Workspace `version` in root `Cargo.toml` when shipping CLI/crates | `0.1.0` |

Rules:

- Tag = `v` + marketing version (`v0.1.0` ↔ `0.1.0`).
- Never reuse a tag or marketing version for a different binary.
- About window already shows `CFBundleShortVersionString` + `CFBundleVersion` (`AboutView`).

---

## Asset naming

When packaging exists, attach assets with stable names:

```text
Arbor-<version>-macos-arm64.dmg
Arbor-<version>-macos-arm64.zip
```

Example: `Arbor-0.1.0-macos-arm64.dmg`

Publish checksums in the release notes (or as `.sha256` files) so Homebrew and users can verify downloads.

---

## Cutting a release (maintainers)

Requires [GitHub CLI](https://cli.github.com/) (`gh`).

1. **Bump versions** in Xcode (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) and Cargo workspace if needed.
2. **Update** [`CHANGELOG.md`](../CHANGELOG.md): move `[Unreleased]` notes into a new `## [X.Y.Z] — YYYY-MM-DD` section (Added / Changed / Fixed). Keep compare links at the bottom current. This file is what **Help → Release History** shows in the app.
3. **Package** the macOS app (from repo root):
   ```bash
   ./scripts/package-macos.sh
   ```
   This writes `dist/Arbor-<version>-macos-arm64.zip` and a `.sha256` sidecar.
4. **Update** [`Casks/arbor.rb`](../Casks/arbor.rb) `version` + `sha256` to match the zip.
5. **Commit** everything and push `main` (changelog must be on `main` before users open Release History for that version).
6. **Tag and push:**
   ```bash
   git tag -a v1.1.0 -m "v1.1.0"
   git push origin v1.1.0
   ```
7. **Create the GitHub Release** with the zip attached (notes should match / summarize the CHANGELOG section):
   ```bash
   gh release create v1.1.0 \
     --title "v1.1.0" \
     --generate-notes \
     ./dist/Arbor-1.1.0-macos-arm64.zip
   ```
8. Users refresh the tap and upgrade: `brew update && brew upgrade --cask arbor`

Dry-run tips:

```bash
gh release list
gh release view v1.0.0
```

---

## Homebrew

Cask lives in this repo at [`Casks/arbor.rb`](../Casks/arbor.rb) (tap the repo by URL).

**macOS requirement:** Apple silicon, **macOS 26 (Tahoe)+** for v1.0.0 (the SwiftUI shell uses Tahoe APIs such as `ToolbarSpacer`).

```bash
brew tap cacuscacus/arbor https://github.com/cacuscacus/arbor
brew trust cacuscacus/arbor   # Homebrew 6+ tap trust
brew install --cask arbor
brew upgrade --cask arbor
```

Cask fields track the GitHub Release asset (`version`, `url`, `sha256`, `app "Arbor.app"`). Do not host binaries elsewhere as the canonical source.

---

## In-app “Check for Updates…” (planned)

No Sparkle. Simple read-only check against the public GitHub API.

### Menu

Add **Check for Updates…** near **About Arbor** in `apps/macos/Arbor/ArborApp.swift` (`.commands` / `CommandGroup` for `.appInfo`).

### Algorithm

1. Read local marketing version from `CFBundleShortVersionString`.
2. `GET https://api.github.com/repos/cacuscacus/arbor/releases/latest`  
   Headers: `Accept: application/vnd.github+json`  
   Unauthenticated requests are fine for a public repo; respect rate limits (cache results; don’t poll every launch aggressively — on menu click is enough for v1).
3. Parse `tag_name`, strip a leading `v`, compare to local version (semver order).
4. UI:
   - Up to date → short confirmation.
   - Newer release → show tag + release name; buttons:
     - **Open Release** → `html_url` in the browser
     - Optional: show/copy `brew upgrade --cask arbor` for Homebrew users

Do **not** download and overwrite `Arbor.app` from the app. Direct-download users update via the release page; Homebrew users via `brew upgrade`.

### Detecting Homebrew installs (optional later)

If the app bundle lives under Homebrew’s Caskroom / Cellar-style paths, prefer showing the brew upgrade hint. Otherwise default to the GitHub release link.

---

## Direct download & Gatekeeper

Users who download a DMG/ZIP outside Homebrew may see:

> “Arbor” can’t be opened because Apple cannot check it for malicious software.

Workaround: Finder → right-click the app → **Open** → confirm. Document this on the release page and in the README install section. Prefer sending developers to Homebrew to avoid this friction.

---

## Security notes

- No Apple signing certificates or notarization credentials — and none should ever be committed.
- Treat GitHub Releases as the only trusted binary source; warn against third-party mirrors.
- Homebrew `sha256` is the primary integrity check for cask users.
- The in-app checker only **reads** public release metadata; it must not execute downloaded payloads.

---

## Explicitly out of scope

- Apple Developer Program, Developer ID, notarization
- Sparkle / appcast / silent `.app` replacement
- Mac App Store distribution

---

## Implementation order (remaining)

1. ✓ Package Release ZIP (`scripts/package-macos.sh`) + GitHub Release + in-repo Homebrew cask
2. Implement **Check for Updates…** via the GitHub Releases API in the macOS app
3. Optionally lower the deployment target once Tahoe-only APIs are behind availability checks
