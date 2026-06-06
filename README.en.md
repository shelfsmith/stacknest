[日本語](README.md) | [English](README.en.md)

# StackNest

[![CI](https://github.com/shelfsmith/stacknest/actions/workflows/ci.yml/badge.svg)](https://github.com/shelfsmith/stacknest/actions/workflows/ci.yml)

A Swift-native, Apple Silicon image library (catalog) manager that can **import** the
original [Stackroom](https://aromaticsapp.blogspot.com/p/stackroom.html) library XML.

> ⚠️ **Compatibility note:** StackNest only **imports** Stackroom library XML (a one-way read). StackNest's own library format (`.stacknest`) is independent and is **not interoperable with Stackroom** (you cannot open or write it back in Stackroom). StackNest is also a **catalog**: a `.stacknest` holds metadata and cover thumbnails, while the actual image/book files stay outside the library (StackNest references their paths).

> **Status:** Pre-alpha (Phase 2.7 in progress — duplicate detection, field / bookType label customization, large-scale sort optimization, and a viewer key-rebinding UI are implemented. Plus the first-run wizard, built-in viewer extensions [two-page spread, per-book page direction, slideshow, resume reading, full-screen, HEIC/AVIF], library CRUD / lock / stamp pane / multi-value filtering / full-text search / smart shelves / keyboard navigation).

## What is this

StackNest reads the Apple Property List XML library files written by
**Stackroom 2.1b** by aroma / aromatics soft, and provides a modern macOS
native experience for browsing and managing very large image collections
(tested at 10,000+ items).

This project is **not affiliated with aroma / aromatics soft**. It is an
independent implementation written from scratch in Swift; it can **import** Stackroom
library XML (import-only), but is not format-interoperable with Stackroom.

## Why this exists

The original Stackroom (last release: 2.1b Build 198, 2019) is an x86_64-only
binary without arm64 native support. While it continues to work via Rosetta 2,
the long-term path requires a native rewrite.

aroma 氏 (the original author) stated the following around 2019 on a thread on the 5ch 新・Mac 板 (Mac board) ([egg.5ch.net/test/read.cgi/mac/1391446507](https://egg.5ch.net/test/read.cgi/mac/1391446507/)):

> ライブラリファイルはただの XML だし、その気があるなら **たぶん Swift で
> 一から作ったほうが早いくらい** だと思います。

(Translation: "The library file is just XML, so if you're motivated, **probably
the fastest way is just to write it from scratch in Swift**.")

This project follows that explicit recommendation. The original Stackroom
binary, source code, icons, UI screenshots, and Sparkle-style branding assets
are **not** redistributed here. Only the on-disk library format is
re-implemented from observation.

- aroma's original Stackroom: <https://aromaticsapp.blogspot.com/p/stackroom.html>
- aroma's release blog: <https://aromaticsapp.blogspot.com/>

## Features

- **Library browsing**: grid / list views, Browser pane (per-attribute column filtering), Detail pane (metadata editing)
- **Search**: toolbar search bar backed by SQLite FTS5 full-text search
- **Multi-value fields**: genre / author / keyword A / B / C are stored as comma-separated values and can be filtered by each individual value in the Browser pane
- **Smart shelves**: dynamic collections from rule lists (N conditions × AND/OR × 4 match types), with an Apple Mail–style condition editor; imported Stackroom smart playlists are evaluated dynamically too
- **Stamp pane**: user-defined chips (5 columns: clear / value / new-add) for batch-applying attributes to multiple books
- **Duplicate detection**: finds same-content books in different directories by SHA-256 byte equality (plus series + volume match). A resolution sheet offers "remove entry only" / "also move file to Trash" and per-group ignore
- **Label customization**: content fields (genre / neta / keyword A / B / C) and the 6 bookType labels can be renamed per-library, reflected consistently across all surfaces (column headers / sort / Detail / stamps / filters / smart shelves)
- **Viewer key rebinding**: Settings ▸ Keys lets you remap every built-in viewer action to any key (conflicts are rejected; per-row / global reset; the help table reflects the current bindings)
- **Large-library performance**: sorting is optimized for thousands–tens of thousands of items (precomputed ICU collation keys speed up the re-sort that runs on every list refresh)
- **Built-in viewer**: dedicated window / full-screen viewing with a unified pipeline for zip/cbz/cbr/7z, folders, single images, and PDF. Fit-to-window (=), pinch / ＋− zoom, drag panning, left/right zone-click + arrow + Space paging, digit keys 0–9 to jump by position (0=start … 9=90%), Tab / ⇧Tab to skip multiple pages. **Two-page spread** (global default ON/OFF + per-book override; cover-alone and auto-solo for wide pages, W), **per-book page direction** (right-to-left / left-to-right, 2-way toggle in Detail and r in the viewer), **slideshow** (auto-advance, s), **resume reading** (per-book last page & spread state persisted), **end-of-book behavior** (stop / next volume / loop, e) with previous/next volume nav ([ / ]), an **open-in-full-screen** setting, and a key-binding help overlay (? / h). **All viewer keys are fully remappable in Settings ▸ Keys.** Minimal bottom HUD (progress). Built-in vs. external viewer is switchable in settings
- **File operations**: add / remove from library / ⌫ remove / ⌘⌫ trash / ⇧⌘R rename / ⌘D file move, each with confirmation dialogs
- **Keyboard navigation**: grid / list arrows, Shift+arrows (range select), ⌘↑↓, Home/End, PageUp/Down, Enter to open
- **Grid item size**: per-library persisted slider
- **Library lock**: per-library SHA-256 (salted) password lock. Touch ID / Apple Watch biometric unlock supported
- **Supported formats**: archives ZIP / CBZ / RAR / CBR / 7z (via libarchive) and PDF (PDFKit); images JPEG / PNG / GIF / WebP / HEIC / HEIF / TIFF / AVIF (via NSImage)
- **First-run wizard**: on first launch, a paged wizard walks through "image-opening method (built-in / external viewer) → (if built-in) viewer initial settings → first library (create / open / import)". Re-showable anytime from Settings ▸ General
- **Import**: migrate an existing Stackroom library XML into the SQLite database

## Requirements

- macOS 14 Sonoma or later (macOS 26 Tahoe is the primary target)
- Apple Silicon native (Universal Binary also produced for x86_64)
- Xcode 26+ to build from source

## Installation (release builds)

Releases are distributed as **ad-hoc-signed Universal builds produced by CI** (not Apple-notarized). Download `StackNest.app` (zip) from [Releases](https://github.com/shelfsmith/stacknest/releases) and move it to `/Applications` (or anywhere).

Because ad-hoc-signed apps are blocked by Gatekeeper, open it **once** with either of the following (subsequent launches are normal double-clicks):

- **Option A (recommended)**: in Finder, **right-click `StackNest.app` → Open**, then click "Open" again in the warning dialog.
- **Option B (Terminal)**: remove the quarantine attribute, then launch:
  ```bash
  xattr -dr com.apple.quarantine /Applications/StackNest.app
  ```

> ⚠️ Ad-hoc signing does not vouch for a verified developer. Install only from a source you trust (this repo's Releases). Apple notarization is under consideration for the future. To build it yourself, see "Build" below.

## Repository structure

```
App/                  -- macOS App target (generated by xcodegen; xcodeproj is gitignored)
Sources/
  StackroomFormat/    -- Stackroom library XML/plist reader (for import)
  LibraryStore/       -- SQLite (GRDB) repository, migrations, FTS5, multi-value normalization
  ImageCache/         -- Thumbnail rendering / caching
  ArchiveAdapter/     -- ZIP / CBZ / RAR / CBR / 7z reading via libarchive
  AppCore/            -- App-level logic (LibrarySettings, AppPreferences, LibraryLock, error types, external viewer launch) — SwiftUI-independent for testability
  StackroomImportCLI/ -- Importer executable (swift run stackroom-import)
Tests/                -- Swift Testing modules (swift-testing)
docs/                 -- Architecture, design notes, smoke checklists
```

## Build

### SPM library and CLI

```bash
swift build
swift test
swift run stackroom-import --xml "$HOME/Library/Application Support/stackroom/Stackroom Library.xml" --out /tmp/stackroom.sqlite --force
```

### macOS App

The `xcodeproj` is gitignored, so generate it first with `xcodegen`:

```bash
cd App && xcodegen && cd ..
xcodebuild \
  -project App/StackNest.xcodeproj \
  -scheme StackNest \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Universal Binary (arm64 + x86_64) release build:

```bash
xcodebuild \
  -project App/StackNest.xcodeproj \
  -scheme StackNest \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  build
```

Or open `App/StackNest.xcodeproj` in Xcode after running `xcodegen`.

See `docs/importer.md` for the CLI Importer reference.

## Using StackNest

After building the app or running `xcodebuild`, launch the macOS app:

```bash
open ~/Library/Developer/Xcode/DerivedData/StackNest-*/Build/Products/Debug/StackNest.app
```

On the very first launch (fresh install, no settings), a first-run wizard guides you through the image-opening method and your first library. On subsequent launches (or when no library is selected) the app shows a title screen with three actions:

- **Create a new library**: pick a location and create an empty `.stacknest` bundle
- **Open an existing library**: pick an existing `.stacknest` bundle
- **Import from a Stackroom Library**: read aroma 氏's original Stackroom XML (`Stackroom Library.xml`) and save it as a new `.stacknest` bundle

### Multi-library support

Each `.stacknest` bundle is an independent library (a macOS bundle containing a SQLite DB and asset directories), and each library opens in its own window. Multiple libraries can be open at once; trying to open the same library twice brings the existing window to the front (`OpenLibraryRegistry` prevents duplicate opens).

The startup mode can be changed in app preferences (`⌘,`) under "Startup":

- **Show title screen** (default)
- **Open last-opened libraries**: reopen every library that was open at quit time
- **Open a specific library every time**: always open one designated library on launch

### Configuring the external viewer

By default, books open in the **built-in viewer**; switch built-in / external in **Settings ▸ 表示 (Display) ▸ 画像ビューワ (Image Viewer) ▸ ビューワ (Viewer)**. To use an external viewer, configure it in **Settings** (`⌘,`). Click "Choose…" and pick an image-viewer app (cooViewer, Avian, Preview, etc.). Without this, the system's Archive Utility would just extract `.zip` files instead of viewing them. The selected viewer is persisted across launches via `UserDefaults`.

Once configured, double-clicking a book in the grid opens the file (or its cover image) directly in the chosen viewer.

### Importing from the command line

The same database that "Import from a Stackroom Library" produces can also be created from the command line with `swift run stackroom-import` (see `docs/importer.md`). Place the resulting SQLite DB inside a `.stacknest` bundle and then use "Open an existing library" to open it.

## Library lock (Phase 2.5b+)

Each `.stacknest` library can be password-protected. Touch ID / Apple Watch biometric unlock is supported.

### Forgotten password

There is no recovery mechanism. The lock is intended as a casual barrier against incidental access, not encryption. If you forget the password, you can **unlock the library by editing the DB directly**:

```bash
sqlite3 /path/to/MyLibrary.stacknest/library.sqlite \
  "DELETE FROM library_settings WHERE key IN ('lock_password_hash', 'lock_password_salt', 'lock_use_biometric');"
```

After running this command, the library is unlocked and can be opened in StackNest again. You may re-configure the lock from File menu ▸ This Library's Settings… (⇧⌘,).

Notes:
- The lock only protects the plaintext password via SHA-256 with salt. The library DB and image files themselves are not encrypted.
- For truly sensitive data, use another mechanism such as Disk encryption or FileVault.

## Roadmap

Development proceeds in incremental phases. Summary:

| Phase | Scope | Status |
|---|---|---|
| 2.1 | Stackroom XML importer (CLI + SQLite/GRDB) | ✅ Done |
| 2.2 | Grid / icon view, thumbnails, archive reading | ✅ Done |
| 2.3 | Sidebar (library / favorites / recent), shelves, detail pane | ✅ Done |
| 2.4 | List view, toolbar / facet filters, FTS5 search, editing | ✅ Done |
| 2.5 | Multi-library, file CRUD, cover editing, undo, lock, naming, auto-classify, PDF import | ✅ Done |
| 2.5k | Grid / list keyboard navigation | ✅ Done |
| **2.6a** | **Smart shelves MVP** (rule-based collections) | ✅ Done |
| **2.6b** | **Built-in viewer core MVP** (full-screen, fit / zoom / pan, paging; PDF / archive / folder / single image) | ✅ Done |
| **2.6b-2** | **Built-in viewer extensions** (two-page spread, per-book page direction, slideshow auto-advance, resume reading, end-of-book next / loop, open-in-full-screen, HEIC / HEIF / TIFF / AVIF support) | ✅ Done |
| **2.6c** | **First-run wizard** (built-in vs external viewer choice, built-in viewer initial settings, first library creation, re-show from Settings) | ✅ Done |
| 2.7 | Polish & performance (duplicate detection, label customization, sort optimization, viewer key-rebinding UI ✅ / naming-format presets and others in progress) | 🔄 In progress |
| 4.0 | Server / client (remote viewing, screen-size-aware image delivery) | 🔭 Future |

Legend: ✅ done / 🔄 in progress / ⏳ planned / 🔭 future

> Phase 3 (the stable-release ceremony) was dismantled in favor of a personal-use, non-redistribution policy; its completed items (icon / branding, etc.) were absorbed into earlier phases.

## License

MIT — see `LICENSE`.

## Acknowledgements

- aroma 氏 / aromatics soft for the original Stackroom and the explicit
  encouragement to rewrite it in Swift.
