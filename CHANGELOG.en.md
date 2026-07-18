# Changelog

[日本語](CHANGELOG.md) | **English**

This file records notable changes to StackNest. It follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).
Releases are self-signed Universal builds (anonymous CN `StackNest Self-Signed`, a fixed identity so TCC permissions persist across builds; not Apple-notarized), distributed from [Releases](https://github.com/shelfsmith/stacknest/releases).

> **About versioning:** Tagged releases start at `0.8.0`. Earlier work was developed by phase (2.1–2.6) without explicit version numbers. The history before tagging is summarized under "Before 0.8.0 (phase-based, untagged)" at the end of this file.

## [0.12.0] - Unreleased — Share-token permissions, CLI / MCP automation, and remote-operation wrap-up (Phases 4.2d–4.2f, C, G3, G4, G12b, G15, G16)

> Distributed as a pre-release: `v0.12.0-rc.1` (2026-07-07) / `v0.12.0-rc.2` (2026-07-18). Rolls up everything added since 0.11.0 (Phase 4.2). Highlights: per-recipient sharing permissions (tokens), control from the command line / AI agents, watch-folder auto-import, a persistent on-disk cache for remote viewing, setting an external image as a book's cover, plus a remote-parity wrap-up (watch-folder tab, admin maintenance, undo/redo) and built-in viewer stabilization.

### Added

**Sharing & permissions**
- **Share tokens (access tiers)**: issue per-recipient tokens with **read / edit / admin** permission and a scope (which libraries are visible). Server settings gain a token list (renameable) and a **per-token QR / URL**.
- **Live token changes**: creating / renaming / regenerating / revoking a token takes effect **without restarting the server** (old tokens are invalidated immediately).
- **Delete books remotely (admin)**: with an admin token, remove / trash books remotely from the list / grid context menu.

**Automation (CLI / MCP / API)**
- **Headless CLI `stacknest-cli`**: drive local / remote libraries from the command line (`libraries` / `list` [filter, browse, sort, scope, fields] / `add` / `rm` / `set` / `detail` / `facets` / `shelves` / `me` / `shelf` CRUD / `watch` / `lock` [password via stdin] / `import` / `relink` / `dedup` / `unlock` / `grant` / `stamp` / `label`). Bundled with the app; connects with a local-access token.
- **MCP server `mcp-stacknest`**: a Model Context Protocol server wrapping the CLI, so AI agents can browse, edit, import, and manage share tokens.
- **OpenAPI 3.1 + Redoc**: the local endpoint is now API-only and serves Redoc API documentation at `/`.

**Import**
- **Watch folders (auto-import)**: watch folders and auto-import archives / image folders dropped into them (per-folder naming presets, first-run preview, import summary banner).
- **Per-library import settings**: override auto-classification (bookType) and thickness threshold per library ("follow the StackNest default" / custom). New "Import" tab in library settings.

**Faster / self-updating remote viewing**
- **Persistent on-disk cache for the remote reader**: cache remote pages / covers to disk (LRU + visible-protection + TTL). **The cache survives reconnect / restart.** Manage size / retention / usage / clear under Settings ▸ "Remote cache".
- **Web-parity prefetch + whole-book prefetch**: reworked prefetch to forward-priority + skip stride, plus a **whole-book prefetch (tier 3)** toggle (off by default) that caches an entire book while idle.
- **Cache coverage bar**: the remote viewer's progress bar visualizes the pages already in the L2 cache as a subtle band.
- **Server-tracking cover cache (G4c)**: covers are version-keyed by a server token, so a remote viewing client **picks up a server-side cover change on list reload / reconnect** (no manual cache clear). The host app reflects remote cover changes without reopening.

**Covers**
- **External image as cover (local G4a / remote G4b)**: set any external image as a book's cover by **dragging & dropping onto the detail-pane cover** (or the "Set External Image as Cover…" menu → crop). **Appearance only; the archive itself is unchanged.** Also available from a native remote client with an RW token (new server `PUT /books/:id/cover-image`).

**Remote editing & web**
- **Rating / unread editable even with an R token**: as shared evaluation / viewing state, a read-only token can still change rating and unread (synced to the server).
- **Server-synced label customization (remote)**: remote detail / facets / stamps reflect server-synced custom labels; RW tokens can edit labels.
- **Web reader end-of-volume nav + PWA**: end-of-volume dialog (next volume / first page / close), plus favicon / apple-touch-icon / PWA manifest.
- **Startup options**: "reopen last-open libraries" now **restores all windows**, and an option to **auto-start remote sharing** at launch (behind the copyright-consent gate).

**Remote parity wrap-up (G12b)**
- **Watch-folder tab + subfolder-mode fix**: watch-folder editing in the remote settings sheet now lives in the "Import" tab. Fixed a bug where the subfolder import mode (subfolderMode) was lost on save.
- **Admin maintenance with progress**: metadata completion and cover compression can now be run remotely as background jobs with a progress indicator.
- **Remote undo / redo (⌘Z / ⌘⇧Z)**: undo and redo metadata edits and deletions from a remote client.
- **Remote-editable naming-format presets**: add / edit / delete naming presets remotely (for capable tiers).
- **Bulk re-import of existing watch-folder contents**: "also import existing files" re-imports files that were already present before watching started.

**Built-in viewer stabilization (G15)**
- **Prevent duplicate viewer windows for the same book**: reworked instance management (local, offline, and remote) so rapidly reopening the same book — even mid-load — never opens it in more than one window. Added an "**Allow multiple viewer windows**" setting (off by default: opening another book reuses the existing viewer window; on: each book opens in its own window).
- **Remote grid cover placeholder**: books without a cover no longer spin indefinitely in the grid — they now show the no-cover icon immediately.
- **Category-specific messages for unsupported formats**: opening a video / document the built-in viewer doesn't support now shows a category-specific message instead of a generic error.

### Changed
- **Unified to share tokens**: the old "access / edit token" UI is folded into the share-token list; user-facing wording standardized to "share token".
- **Local-access settings moved to app settings**: the local-control (CLI / MCP) settings moved out of the sharing window into an app-settings tab, renamed "Local access".
- **Settings tabs reorganized**: General / Import / Display / Viewer keys (the Import tab merges auto-classification and watch folders).
- **Copyright warning before sharing**: shown (suppressible) before the server starts.
- Wording "remote / offline viewer" → "**remote / offline browser**".
- **Parallelized infinite-scroll live sync**: the remote browser now fetches catch-up pages in parallel, improving perceived responsiveness.

### Fixed
- **Stale remote covers**: after replacing a cover remotely, the editing detail pane or another viewing client could keep showing the old cover — fixed (bypass the cover fetch's HTTP cache [`immutable`] on replace / version-key the cover cache by server token / host reflects per-book).
- **Reopened closed windows on startup restore** — fixed by switching to an incremental `NSWindow.willClose` scheme (independent of termination hooks).
- **Duplicate delete-confirmation across multiple windows** — fixed an existing bug with a notification focus guard.
- **Token invalidation**: regenerate / revoke now invalidates old tokens; fixed tokens reappearing after deleting all tokens (default grants synced to the current token, one-time migration marker).
- **EXIF orientation** now applied to the built-in viewer / thumbnails; warning for missing watch paths; automatic port re-pick on conflict.
- **Security**: CLI passwords read from stdin (no argv exposure); MCP `add` argument-smuggling guard (`--`); local endpoint Web UI removed (API-only).
- **Remote undo no longer overwrites concurrent edits**: undoing a metadata edit now restores the correct pre-edit value instead of clobbering another client's concurrent change.
- **Restoring a trashed book now restores the file too**: undoing (⌘Z) a remote delete restores the file from Trash to its original location, not just the catalog entry.
- **Suppressed duplicate windows after volume navigation**: fixed the built-in viewer occasionally reopening the same book in a second window right after advancing a volume.
- **List now scrolls to the top when filtering**: fixed the list staying at the old scrolled-down position when searching/filtering after scrolling far down (position is still preserved for post-edit and live-sync updates).
- **Security**: closed a path where the remote restore operation could be abused to move arbitrary files.
- Aligned the delete-confirmation dialog wording to reflect that the action can be undone with ⌘Z (including remote deletes).
- Fixed empty (unset) tag fields not clearing back to empty on undo (⌘Z) after typing a value.

## [0.11.0] - Unreleased — Remote sharing / native client / offline / remote editing (Phase 4.2)

> Distributed as prereleases: `v0.11.0-rc.1` (2026-06-14, Phase 4.2b = viewing / offline foundation) and `v0.11.0-rc.2` (2026-06-21, Phase 4.2c = parity & remote editing).

### Added
- **Native remote client** (4.2b-1b-2b): connect from StackNest on another Mac to a sharing server and full-browse via sidebar / facets / filters / grid / list / detail pane plus the built-in viewer; reading progress synced to the server. Adds server `/shelves`, `/facets`, `/books/:id/detail`, and `/books` with `scope+filter+browse`.
- **Offline download** (4.2b-2): save remote books locally (`OfflineStore` + `index.json`) and browse / read them **without a connection** (resume). Launch from the title screen / File menu "Offline (downloaded)".
- **Batch download / delete** (4.2b-5, 4.2c-3): ⌘ / Shift multi-select on remote / offline for batch download / delete (unified on native multi-select).
- **Remote / offline volume navigation** (4.2b-4, 4.2b-6): previous / next volume in the built-in viewer works on remote (adjacent-volume stream, may be un-downloaded) and offline (consecutive volumes). In-progress volumes offer "continue / from start".
- **Remote search** (4.2c-3): toolbar search (live filter + 300 ms debounce + clear).
- **Remote editing (RW token)** (4.2c-6a, 4.2c-6b): edit in the detail pane — single / multi-select batch metadata edits (progress N/M + cancel), stamp tagging / definition editing, **cover page selection / crop editing**, and reading-direction changes. Stamp definitions sync via a server-resident canonical store; covers regenerate the thumbnail server-side.
- **Remote browser-state persistence** (4.2c-7): facets / sort / grid / filters / sidebar saved per (server, library) in UserDefaults (not propagated across libraries).
- **keywordC as a full column** (4.2c-6c): added to local / remote list columns and sort (incl. current-value display in remote multi-select editing).

### Changed
- **Remote grid brought to local parity** (4.2c-4): ⌘ / Shift multi-select, size slider, right-click sort, and toolbar layout unified with local. Local "series" sort is now a two-level series→volume sort.
- **Dual-sync of remote viewer progress** (4.2c-5): write-sync progress both ways between remote (downloaded) and offline, resolving to the max page on open.
- Updated README (JA / EN) and the in-app Help to document remote sharing / client / offline / editing (RW editing supported).

### Fixed
- Many remote / offline UX fixes (single-click list selection, fixed detail-pane width, cancel / progress / selection-rewind during downloads, viewer resume, "last read" column updates, web search firing during IME composition, etc.).
- Fixed remote grid keeping the old cover after a cover swap, and the remote grid not applying crop (added `coverVersion` / `coverCropRectJSON` to the list DTO).
- Security: hide `path` from server responses (prevent leakage), hide "Reveal in Finder" in read-only mode, and allowlist facet / browse column identifiers (SQL injection mitigation).

## [0.10.0] - 2026-06-08 — Copy file name & release hardening (B24)

### Added
- **Right-click "Copy file name" (B24)**: Added to the grid/list right-click menu. Copies the extensionless file name to the clipboard (enabled for single selection only; grayed out for multi-selection / path-less items).

### Changed
- Releases are now published as full releases (no longer prerelease).
- Updated install instructions for **macOS 15 Sequoia and later Gatekeeper behavior** ("right-click → Open" was removed → allow via System Settings "Security" → "Open Anyway", or strip quarantine with `xattr`).

## [0.9.0] - 2026-06-07 — Library safety & DB repair (Phase 2.8 / 2.9)

### Added
- **DB preventive safety (B22)**: On closing any session that made edits, a generational backup is taken automatically into `Backups/` inside the bundle (SQLite Online Backup API; view-only/no-edit sessions are skipped). The number of generations to keep is per-library configurable from 1–20 (default 5).
- **Integrity check (B22)**: On opening a library, `PRAGMA quick_check` runs; if corruption is detected it offers "Restore from the latest healthy backup?". Settings gain manual integrity-check / back-up-now / reveal-backups-folder buttons.
- **In-app DB repair `.recover` (B23)**: When restoring from a backup isn't possible, "Try repair with .recover" runs the system `sqlite3 .recover` to salvage what it can. It reports how many books were recovered and, if healthy, swaps it in and opens (the corrupt originals are kept as `library.corrupt-*` / `library.prerecover-*`).
- **Relink missing files (A19)**: Re-link books whose underlying file/folder moved. Right-click "Reassign file…" (immediate) and the menu "Detect broken links…" (per-item list + folder-wide remap).
- **Recovery guide**: Added `docs/recovery-guide.md` (manual `sqlite3 .recover` steps and an explanation of the retained files).

### Fixed
- **NFC normalization**: Fixed a bug where series/titles derived from macOS filenames (NFD) were treated as different strings from typed/imported ones (NFC), splitting browse facets and missing filter matches. Text is now NFC-normalized on write, and existing data is backfilled by migration v16.

## [0.8.0] - 2026-06-06 — Polish & performance (Phase 2.7)

### Added
- **Duplicate detection (A20 / B11)**: Detect same-content books in different directories by SHA-256 byte match (plus series+volume match). Resolution sheet (remove catalog entry only / also move file to Trash / ignore group).
- **Label customization (A22 / A23)**: Rename content fields and bookType display names per library, reflected consistently everywhere (column headers, sort, detail, filters, stamps, browse, smart shelves).
- **Viewer key-rebinding UI**: Freely reassign every viewer action key in the Settings "Keys" tab (conflicts rejected; help auto-generated).
- **Multiple naming-format presets (B6)**: Save several naming formats and pick one at rename time.
- **Distribution**: Started releasing ad-hoc-signed Universal builds via CI (GitHub Actions) — the first tagged release.

### Changed
- **Sort performance optimization (B9)**: DSU + ICU sort key (`ucol_getSortKey`) speeds up sorting for large libraries (notably improves perceived startup at a realistic 5,000-item scale).

---

## Before 0.8.0 (phase-based, untagged)

Development history prior to tagged releases, by phase (**newest first**). Detailed specs live in the planning repo; the README "Roadmap" is the summary.
(Early-phase dates are based on the planning repo's final smoke / decision logs. 2.2 has no standalone completion record; its 2026-05-03 to 05-07 range is inferred from the related spec through the next phase's smoke.)

### Phase 2.6g — 2026-06-04 — Keychain-free biometric lock
- armedHash approach removes Keychain access from the unlock path (fixes the repeated prompt; no plaintext stored).

### Phase 2.6f — 2026-06-04 — Docs & in-app help
- README (JA/EN) / CONTRIBUTING polish; Help menu turned into an in-app help page.

### Phase 2.6e — 2026-06-04 — Rebrand & de-identify
- Identifier cleanup (`app.shelfsmith.stacknest`) and GitHub migration (`shelfsmith`).

### Phase 2.6d — 2026-06-04 — Safety & cleanup
- Lock file to prevent simultaneous multi-Mac opening + legacy-name cleanup + in-app Help / About.

### Phase 2.6c — 2026-06-03 — First-run wizard
- Built-in vs external viewer, built-in initial settings, first library creation, re-show from Settings.

### Phase 2.6b-2 — 2026-06-02 — Built-in viewer extensions
- Two-page spread, per-book page direction, slideshow auto-advance, resume reading, end-of-book behavior (next volume / loop), open-in-full-screen, HEIC/HEIF/TIFF/AVIF support.

### Phase 2.6b — 2026-06-01 — Built-in viewer core
- Dedicated window, full-screen, fit / zoom / pan, paging; PDF / archive / folder / single image.

### Phase 2.6a — 2026-05-31 — Smart shelves MVP
- Rule-based collections (rule list, dynamic evaluation, AND-combined with facets/FTS).

### Phase 2.5k — 2026-05-29 — Keyboard navigation
- Grid / list arrow movement, range extension, Enter to open, unified Home/End/PageUp/Down.

### Phase 2.5g–2.5i — 2026-05-28 — Auto-classify, cover pipeline, PDF (v0.6.5)
- bookType auto-classification made configurable (new imports only, threshold, with manual relabel).
- Cover crop UI (wide covers, tall-cover normalization) + cover compression (downsample on save, regenerate all covers).
- PDF cover import & PDF page-count detection (incl. PDFs inside zips); adding single image/PDF/movie/text.

### Phase 2.5f — 2026-05-27 — "Recently opened libraries" path consolidation
- Consolidated the update path to one place (history updates on fixed-library launch / Finder double-click too).

### Phase 2.5e — 2026-05-27 — Per-extension external helpers
- Per-extension helper mapping / separate slideshow & zip helpers / pass folder to external helper.

### Phase 2.5 (core) — 2026-05-24 — Multi-library & file operations
- Multiple libraries at arbitrary locations (Cmd+O, recents list, macOS tabs), per-library password lock + Touch ID, image-folder books (no zip), file move / rename (bidirectional tokens, preview), filename-parser fix, series + volume split (migration v10), cover editing (D&D + page pick from zip), delete safety (Undo), detail-pane Tab navigation.

### Phase 2.4 — 2026-05-09 — Editing & filters
- Detail-pane editing (tag dropdowns, memo, bookType), three toolbar filters (unseen / rating / bookType), facet filter columns (browse), FTS5 (trigram) full-text search, stamp view, tag "→" jump.

### Phase 2.3 — 2026-05-07 — Browser core
- Sidebar (library / favorites / recent), manual shelves, detail pane (display), incremental search, list view, rating / unseen / bookType (menu + shortcuts), drag-and-drop to favorites.

### Phase 2.2 — 2026-05-03 to 05-07 — Display basics
- Grid / icon view, thumbnail generation, archive reading (zip/cbz/cbr/7z), external viewer selection.

### Phase 2.1 — 2026-05-02 — Compatible importer (the initial foundation)
- A CLI importer that parses Stackroom's library XML into SQLite (GRDB). Established the data model (title / author / genre / keywords / relation / memo / rating / unseen / page count / cover / bookType).

[0.10.0]: https://github.com/shelfsmith/stacknest/releases/tag/v0.10.0
[0.9.0]: https://github.com/shelfsmith/stacknest/releases/tag/v0.9.0
[0.8.0]: https://github.com/shelfsmith/stacknest/releases/tag/v0.8.0
