# Changelog

[日本語](CHANGELOG.md) | **English**

This file records notable changes to StackNest. It follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).
Releases are ad-hoc-signed Universal builds (not Apple-notarized), distributed from [Releases](https://github.com/shelfsmith/stacknest/releases).

> **About versioning:** Tagged releases start at `0.8.0`. Earlier work was developed by phase (2.1–2.6) without explicit version numbers. The history before tagging is summarized under "Before 0.8.0 (phase-based, untagged)" at the end of this file.

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
