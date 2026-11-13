# Remote SSH locations — feasibility analysis

Status: **implementation in progress** (`feature/ssh-locations`)
Date: 2026-08-15 · Linked from [ROADMAP.md](ROADMAP.md) Phase 6

## Executive summary

Adding **SSH directories as first-class locations** is technically **feasible** and aligns with Arbor’s vision (split local↔remote, DnD across locations, remote terminal). It does **not** work cleanly as a thin `ssh://` varnish over today’s `URL` + `FileManager` model.

| Dimension | Assessment |
|-----------|------------|
| Product fit | High — split panes, transfers, terminal, and agents already imply “work where the folder is” |
| Transport risk | Medium — SFTP + OpenSSH are mature |
| Architecture risk | **High** — nearly every path assumes local filesystem identity |
| Recommended foundation | `Location` / `Volume` / `Connection` / `ItemRef` + async `FileProvider` |
| Recommended transport | **SFTP** for browse/mutate · **rsync-over-SSH** for large trees · **OpenSSH** for terminal |
| Avoid as core | **sshfs / FUSE** (optional “Mount in Finder” later only) |

**Rough effort (one experienced Swift + Rust maintainer):** ~4–7 months for a solid experience; **8–14 weeks** for a constrained SSH browse MVP *after* the provider abstraction.

---

## Why this is interesting

- Split view: one pane on `~/Projects`, one on `user@build:~/srv` — same UI language.
- DnD between panes: Arbor turns gestures into upload / download / remote rename (not shell string soup).
- Terminal and **Run Agent Here…** follow the focused location’s host once connected.
- Favorites / sessions remember remote roots (with reconnect UI when offline).

---

## Current codebase assumptions (blockers)

The macOS shell still owns FS work via `LocalFileService` / `FileOperations`; `arbor-core` listing exists but is not wired into the UI (`ContentView` notes FFI later). Almost everything keys on **local `URL` / `PathBuf`**:

| Area | Today | Conflict for SSH |
|------|--------|------------------|
| Identity | `FileEntry.id: URL`, selection `Set<URL>` | No connection/user/port in identity; `standardizedFileURL` is wrong for remotes |
| Listing / metadata | `FileManager`, `URLResourceValues` | Need SFTP list/stat; package / localized kind heuristics differ |
| Navigation / crumbs | Parent walk to `/`, “Macintosh HD” | Need location-rooted breadcrumbs |
| Tabs / split | Independent panes with `URL` roots | Structure is good; root type must become `ItemRef` / location |
| DnD / transfer | `.fileURL` pasteboard, `FileManager.copy/move` | Need private UTType + transfer jobs; default **copy** across volumes |
| Undo / trash | Local URL pairs + Finder Trash | No universal remote Trash; undo must be capability-aware recipes |
| Watchers | `DispatchSource` on `O_EVTONLY` | No portable SFTP watcher → poll + post-mutation refresh |
| Search | `fd` / Spotlight / local walk | Remote `fd`/`find` when available; cancelable SFTP walk fallback |
| Terminal / agents | Local `$SHELL`, `{folder}` as host path | Need `ExecutionContext.local` vs `.remote(connection, cwd)` |
| Favorites / session | Path strings + `fileExists` → Home | Offline remotes must restore as **disconnected**, not silently Home |
| Icons / QL | `NSWorkspace` + Quick Look on file URLs | Generic icons first; optional materialize-to-cache for preview |

**Bottom line:** the hard part is not “talk SSH” — it is retiring the assumption that every Arbor item is a path `FileManager` can open.

---

## Recommended model

Keep identities separate (do **not** encode credentials in paths):

```text
Connection  →  how to authenticate / reach host (OpenSSH config alias, keys, jump)
Volume      →  filesystem semantics + capabilities (case, trash, watcher, rename)
Location    →  sidebar / session root (e.g. /home/alice, /srv/www)
ItemRef     →  volumeID + normalized provider path (stable across named locations)
```

Provider surface (conceptually in `arbor-core`, async + cancelable):

- `list` / `stat` / `create` / `rename` / `remove`
- `transfer` (jobs with progress)
- `search` / `watch` (capability-gated; watch may be poll-only)

UI receives immutable snapshots; connection pools live outside pane/tab lifetime.

---

## Transport choices

| Approach | Role |
|----------|------|
| **SFTP** | Baseline for browse + mutations; structured ops, no `ls` parsing |
| **rsync over SSH** | Optional accelerator for large trees; probe + fallback to SFTP |
| **scp** | Limited fallback only |
| **`/usr/bin/ssh -tt`** | Remote terminal / agent host execution |
| **sshfs** | Optional later “Mount in Finder”; **not** internal representation |

Cross-location DnD matrix (product intent):

- same volume → move/copy like today  
- local ↔ remote → upload / download jobs  
- remote A ↔ remote B → stream / relay (never pretend rename)  
- Arbor → Finder → file promises / materialize on demand  
- Finder → Arbor remote → accept `.fileURL` and upload  

Safe **move** across locations: copy → verify → delete source (never delete first).

---

## Credentials (macOS)

Priority:

1. `~/.ssh/config` aliases (`ProxyJump`, IdentityFile, …)
2. `ssh-agent` / `SSH_AUTH_SOCK`
3. Keys on disk (passphrase via agent / Keychain — do not copy private keys into Arbor storage)
4. Password in **Keychain** only with explicit “Remember”
5. Interactive prompt

Non-negotiable: validate `known_hosts`; show fingerprint on first connect; block on host-key change until the user decides. Never silent auto-accept.

Prefer structured SFTP APIs over shelling out `rm`/`mv` strings (injection + encoding hazards).

---

## Feature capability matrix (post-SSH)

| Feature | Local | Remote MVP | Later |
|---------|-------|------------|-------|
| List / navigate | ✓ | ✓ | |
| Create / rename / delete | ✓ | ✓ (delete = permanent unless Trash capability) | Trash where supported |
| Split local + remote | ✓ structure | ✓ after abstraction | |
| DnD cross-location | local only | copy jobs | rsync, remote↔remote |
| Live refresh | FSEvents-like | poll visible dir | optional remote agent |
| Search | fd / Spotlight | remote fd/find or slow walk | |
| Terminal / agents | local | `ssh -tt` + remote cwd | ControlMaster polish |
| Quick Look / thumbs | local QL | generic icons | materialize cache |
| Show in Finder / Open in Cursor | ✓ | disable or alternate actions | Cursor Remote SSH if CLI allows |
| Undo | strong | conditional / capability-aware | |

---

## Phased plan (into ROADMAP Phase 6)

### 6a — Provider abstraction (local still looks the same)

- Introduce `ItemRef` / Location / Volume / Connection IDs
- `LocalFileProvider`; migrate listing, mutations, undo, favorites, sessions
- Capability flags; async listings
- **Exit:** no feature requires `ItemRef` to be a file URL

~4–7 weeks

#### Implementation log

**2026-08-15 — first slice (`feature/ssh-locations`)**

- Added provider-neutral `ItemRef`, `FileLocation`, `FileVolume`, connection/volume/location IDs, provider kind, and capability flags.
- Added async `FileProvider` listing/metadata boundary, `FileProviderRegistry`, structured errors, and `LocalFileProvider`.
- Browser directory reload and single-item Get Info now call the provider asynchronously and discard stale/cancelled results.
- `LocalFileService` remains as a compatibility facade for unmigrated URL call sites; `FileEntry.id` and search-result identity are now canonical `ItemRef`s with an explicit optional local URL bridge.
- Added provider mutation primitives for create, rename, move/copy, Trash and remove; legacy `FileOperations` now delegates local filesystem work to `LocalFileProvider`.
- Undo/redo recipes now store provider-neutral `ItemRef` pairs and execute through provider primitives instead of calling `FileManager` directly.
- Corrected item identity to **volume + provider path** (stable local volume UUID when available); named Locations are navigation roots, so the same file does not gain a new identity when reached through a favorite.
- Browser navigation/history, pane/tab cloning and queued new-window roots now store `ItemRef`; local-only views use an explicit temporary URL bridge.
- Session schema v2 persists pane `ItemRef`s and migrates v1 `panePaths`; non-local refs survive restore instead of falling back to Home while disconnected.
- Favorites persist `ItemRef` and migrate the previous path-only payload.
- Browser selection, inline rename, list/icon indexing, context targets and in-process drag state now use `ItemRef`; Finder interoperability still publishes and accepts public `fileURL` payloads for local items.
- Local volume lookup walks to an existing ancestor, and rename/transfer receipts preserve the destination volume ID so path-changing operations do not destabilize selection identity.
- Browser create/rename/move/copy/Trash call sites now use async `FileProvider` mutations; `BrowserListingDidChange` broadcasts `ItemRef` folders so split panes refresh without URL bridging.
- Directory listing watchers take `ItemRef` and honor `.nativeWatch`; volumes without it stay idle until remote polling lands in 6b.
- Added an explicit materialization contract; local providers return intrinsic URLs while unsupported providers render generic icons and never fabricate file URLs.
- Browser rendering, breadcrumbs, Get Info, WorkspaceActions, focused commands, agent requests and terminal requests now accept provider-neutral refs/context; unavailable providers show a safe disconnected state and remote terminal focus never falls back to Home.
- Undo/redo is async and provider-routed, exact-destination transfer is part of the provider contract, and non-interruptible mutations always reconcile their receipts. Trash without a restorable receipt no longer creates an invalid undo recipe.
- Capabilities gate mutations, metadata, native watches and local integrations. Quick Look generation remains local-only through the materialization boundary; remote caching is intentionally 6e.
- **6a exit reached:** no browser feature requires an `ItemRef` to masquerade as a file URL. SSH transport/UI remains 6b; cross-provider transfer jobs remain 6c; remote execution remains 6d.

### 6b — SSH MVP

- Connect sheet, Keychain, host-key UX, SFTP pool
- Browse + basic mutations; favorites / session as reconnectable remotes
- Manual refresh + visible-dir polling; Copy Remote Path
- **Out of MVP:** QL, edit-upload, fast recursive search, cross-location move, remote Trash

~5–8 weeks

#### Implementation log

**2026-08-15 — first usable SSH slice (`feature/ssh-locations`)**

- Added a persistent SSH Location catalog with stable connection/volume/location IDs. Catalog data is atomic, mode `0600`, contains no credentials, and registers providers before browser-session restoration.
- Added the Places `+` flow for OpenSSH config aliases or direct host/user/port endpoints. Concrete aliases are discovered from `~/.ssh/config` and recursive `Include` files without expanding wildcard `Host` declarations.
- Added a bundled Rust newline-delimited JSON helper using system OpenSSH plus `openssh-sftp-client`. This preserves ssh config, agent, identity files, and ProxyJump while using structured SFTP operations instead of parsing `sftp` output.
- Host checking is strict. Unknown keys open an explicit fingerprint review flow; accepted keys are appended to `~/.ssh/known_hosts` with mode `0600`. Existing mismatched entries are never replaced automatically.
- SSH providers now lazily pool one helper per connection and support listing, metadata, create file/folder, rename/move on the same remote volume, permanent delete, reconnect, and five-second visible-pane polling.
- Remote roots restore safely while offline, retain provider-neutral breadcrumbs and identity, and expose Copy Remote Path. Quick Look, local integrations, remote Trash, remote copy, and cross-provider DnD remain capability-gated.
- Distribution packaging builds and embeds the helper before deep ad-hoc signing.
- Current authentication cut is intentionally non-interactive: OpenSSH config, ssh-agent, and default key files. Password/passphrase prompts and optional Keychain-backed credentials remain follow-up 6b work.

### 6c — Transfer engine + DnD

- Jobs (progress / cancel / retry / conflicts)
- local↔remote; custom drag UTType; file promises to Finder
- rsync probe + SFTP fallback; safe move = copy+verify+delete

~4–7 weeks

### 6d — Remote terminal & agents

- `ExecutionContext`; follow-folder only within same connection
- Clear “on host.example.com” labeling for Run Agent Here…

~2–4 weeks

### 6e — Search, preview, polish

- Remote search backends; thumbnail/QL materialization limits
- Get Info fields that SFTP actually has; optional Cursor Remote; bandwidth / error UI

~6–10 weeks

---

## Decision gates (approve before coding remotes)

1. Do **not** fake remotes as `URL(fileURLWithPath:)`.
2. Do **not** build first-class locations on sshfs.
3. Ship provider abstraction **before** the first remote pane.
4. Keep Connection / Volume / Location / Path distinct.
5. All remote APIs async, cancelable, capability-aware.
6. SFTP baseline · rsync optimization · OpenSSH for terminal.

---

## Relation to other phases

- **Phase 0** “move FS into `arbor-core`” and **6a** are the same strategic bet — remote forces the abstraction early.
- **Phase 4** (Git / quick diff) and browser polish can still ship first; remote does not block them.
- **Phase 6** SMB / NFS / S3 become additional providers once `FileProvider` exists — SSH is the first hard provider that proves the model.
