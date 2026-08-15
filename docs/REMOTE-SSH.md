# Remote SSH locations — feasibility analysis

Status: **analysis / planned** (not scheduled for immediate implementation)  
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
ItemRef     →  locationID + normalized remote path
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

### 6b — SSH MVP

- Connect sheet, Keychain, host-key UX, SFTP pool
- Browse + basic mutations; favorites / session as reconnectable remotes
- Manual refresh + visible-dir polling; Copy Remote Path
- **Out of MVP:** QL, edit-upload, fast recursive search, cross-location move, remote Trash

~5–8 weeks

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
