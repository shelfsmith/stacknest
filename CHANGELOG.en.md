# Changelog

[日本語](CHANGELOG.md) | **English**

This file records notable changes to StackNest. It follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).
Releases are ad-hoc-signed Universal builds (not Apple-notarized), distributed from [Releases](https://github.com/shelfsmith/stacknest/releases).

> **About versioning:** Tagged releases start at `0.8.0`. Earlier work was developed by phase (2.1–2.6) without explicit version numbers. The history before tagging is summarized under "Before 0.8.0 (phase-based, untagged)" at the end of this file.

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
(Foundational phases 2.1–2.5 core are recorded at month granularity only, so dates are shown as "2026-05".)

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

### Phase 2.5 (core) — 2026-05 — Multi-library & file operations
- Multiple libraries at arbitrary locations (Cmd+O, recents list, macOS tabs), per-library password lock + Touch ID, image-folder books (no zip), file move / rename (bidirectional tokens, preview), filename-parser fix, series + volume split (migration v10), cover editing (D&D + page pick from zip), delete safety (Undo), detail-pane Tab navigation.

### Phase 2.4 — 2026-05 — Editing & filters
- Detail-pane editing (tag dropdowns, memo, bookType), three toolbar filters (unseen / rating / bookType), facet filter columns (browse), FTS5 (trigram) full-text search, stamp view, tag "→" jump.

### Phase 2.3 — 2026-05 — Browser core
- Sidebar (library / favorites / recent), manual shelves, detail pane (display), incremental search, list view, rating / unseen / bookType (menu + shortcuts), drag-and-drop to favorites.

### Phase 2.2 — 2026-05 — Display basics
- Grid / icon view, thumbnail generation, archive reading (zip/cbz/cbr/7z), external viewer selection.

### Phase 2.1 — 2026-05 — Compatible importer (the initial foundation)
- A CLI importer that parses Stackroom's library XML into SQLite (GRDB). Established the data model (title / author / genre / keywords / relation / memo / rating / unseen / page count / cover / bookType).

[0.9.0]: https://github.com/shelfsmith/stacknest/releases/tag/v0.9.0
[0.8.0]: https://github.com/shelfsmith/stacknest/releases/tag/v0.8.0
