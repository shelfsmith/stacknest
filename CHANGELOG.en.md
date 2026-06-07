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

Development history prior to tagged releases, by phase (oldest first). Detailed specs live in the planning repo; the README "Roadmap" is the summary.

### Phase 2.1 — Compatible importer (the initial foundation)
- A CLI importer that parses Stackroom's library XML into SQLite (GRDB). Established the data model (title / author / genre / keywords / relation / memo / rating / unseen / page count / cover / bookType).

### Phase 2.2 — Display basics
- Grid / icon view, thumbnail generation, archive reading (zip/cbz/cbr/7z), external viewer selection.

### Phase 2.3 — Browser core
- Sidebar (library / favorites / recent), manual shelves, detail pane (display), incremental search, list view, rating / unseen / bookType (menu + shortcuts), drag-and-drop to favorites.

### Phase 2.4 — Editing & filters
- Detail-pane editing (tag dropdowns, memo, bookType), three toolbar filters (unseen / rating / bookType), facet filter columns (browse), FTS5 (trigram) full-text search, stamp view, tag "→" jump.

### Phase 2.5 — Multi-library & file operations
- Multiple libraries at arbitrary locations (Cmd+O, recents list, macOS tabs), per-library password lock + Touch ID, image-folder books (no zip), file move / rename (bidirectional tokens, preview), filename-parser fix, series + volume split (migration v10), cover editing (D&D + page pick from zip), delete safety (Undo), detail-pane Tab navigation.
- **2.5e** Per-extension helper mapping / separate slideshow & zip helpers / pass folder to external helper.
- **2.5f** Consolidated the "recently opened libraries" update path.
- **2.5g** bookType auto-classification made configurable (new imports only, threshold, with manual relabel).
- **2.5h** Cover crop UI (wide covers, tall-cover normalization) + cover compression (downsample on save, regenerate all covers).
- **2.5i** PDF cover import & PDF page-count detection (incl. PDFs inside zips); adding single image/PDF/movie/text.
- **2.5k** Grid / list keyboard navigation (arrows, range extension, Enter to open, unified Home/End/PageUp/Down).

### Phase 2.6 — Smart shelves, built-in viewer, wizard, safety, rebrand
- **2.6a** Smart shelves MVP (rule-based collections).
- **2.6b** Built-in viewer core (dedicated window, full-screen, fit / zoom / pan, paging; PDF / archive / folder / single image).
- **2.6b-2** Two-page spread, per-book page direction, slideshow auto-advance, resume reading, end-of-book behavior (next volume / loop), open-in-full-screen, HEIC/HEIF/TIFF/AVIF support.
- **2.6c** First-run wizard (built-in vs external viewer, built-in initial settings, first library creation, re-show from Settings).
- **2.6d** Lock file to prevent simultaneous multi-Mac opening + legacy-name cleanup + in-app Help / About.
- **2.6e** Rebrand / identifier cleanup (`app.shelfsmith.stacknest`) and GitHub migration (`shelfsmith`).
- **2.6f** README (JA/EN) / CONTRIBUTING polish; Help menu turned into an in-app help page.
- **2.6g** Keychain-free biometric lock (armedHash approach; removes Keychain access from the unlock path).

[0.9.0]: https://github.com/shelfsmith/stacknest/releases/tag/v0.9.0
[0.8.0]: https://github.com/shelfsmith/stacknest/releases/tag/v0.8.0
