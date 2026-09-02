# Architecture

## Module graph

```
                        ┌──────────────┐
                        │   App/       │
                        │  (SwiftUI)   │
                        └──────┬───────┘
                               │ depends on
      ┌──────────┬─────────────┼──────────────┬──────────────┐
      ▼          ▼             ▼              ▼              ▼
┌───────────┐ ┌──────────┐ ┌──────────────┐ ┌───────────┐ ┌──────────────┐
│  AppCore  │ │ImageCache│ │ArchiveAdapter│ │RemoteClient│ │LibraryServer │
│  (logic)  │ │(ImageIO) │ │ (libarchive) │ │  (URLSession)│ │   Core      │
└─────┬─────┘ └──────────┘ └──────────────┘ └─────┬─────┘ └──────┬───────┘
      │                                            │              │
      ▼                                            ▼              ▼
┌──────────────┐                            ┌──────────────────────────┐
│ LibraryStore │                            │    LibraryServerAPI      │
│   (GRDB)     │◀───────────────────────────│      (DTOs only)         │
└──────┬───────┘                            └──────────────────────────┘
       │ depends on
       ▼
┌──────────────────┐
│ StackroomFormat  │
│  (PropertyList)  │
└──────────────────┘
```

Executables: `LibraryServer`, `StackroomImportCLI`, `StackNestCLI` (`stacknest-cli`,
shipped inside the app bundle under `Contents/Helpers/`).

## Module responsibilities

- **StackroomFormat** — Read (import only) the original Stackroom Apple plist
  library format; StackNest imports Stackroom XML one-way and does not write it
  back. `Codable` structs that mirror the on-disk schema. No persistence
  concerns. Pure value types. Reusable as a CLI tool dependency.
- **LibraryStore** — SQLite repository (via GRDB.swift) that holds the
  imported library, including books, playlists, and cached metadata. Owns the
  schema migration story.
- **ImageCache** — Two-tier (memory + disk) thumbnail cache. Renders
  `<ID>/thumbnail.jpg` on demand, resizes via ImageIO, evicts via LRU.
- **ArchiveAdapter** — Reading abstraction over ZIP / CBZ / RAR / CBR / 7z,
  implemented via libarchive. (Historical note: the earliest Phase 2.1 build
  read ZIP only; the remaining archive formats landed in later phases and all
  are supported now.)
- **EPUBAdapter** — The contract for reading EPUBs (`EPUBReading`: open,
  cover image, title / author / language, reading direction). Zero
  dependencies. `AppCore` depends only on this contract, never on a library.
- **WashiEPUBAdapter** — The current implementation of that contract on
  [shunnag/Washi](https://github.com/shunnag/Washi) (MIT, pinned to a
  revision). It is the only target that imports `WashiCore`, and an
  import-boundary test keeps it that way. Registered once at the app
  composition root; replacing the library means writing another adapter
  that passes the shared contract tests and changing that one line.
- **AppCore** — UI-independent application logic that the App target and the
  CLI both need: import (`BookImporter`), filename parsing (`FilenameFormat`),
  watch-folder scan planning (`WatchScanPlanner`), settings (`LibrarySettings`),
  library open locks, and throttled I/O for background scans
  (`ThrottledIOExecutor`). Testable via `swift test`, unlike the App target.
- **LibraryServerAPI** — Wire-format DTOs shared by the server and every
  client. No I/O, no persistence — pure `Codable` value types.
- **LibraryServerCore** — The sharing server: HTTP routing, share tokens and
  their scopes/tiers, SSE, and image delivery.
- **RemoteClient** — Client side of the above (`URLSession`), used by the
  native remote browser and by the offline store.
- **App/** — SwiftUI macOS application target. Glues the libraries into
  the user-facing experience: sidebar, browser, item grid, item detail,
  external helper launching.

> Kept honest as of 0.12.1. This list previously named only five modules and
> omitted `AppCore`, which is where most non-UI logic actually lives.

## Strict layering

Lower layers do not import upper layers. Specifically:

- `StackroomFormat` has no SQLite, no SwiftUI, no AppKit dependencies.
- `LibraryStore` may import `StackroomFormat` but no UI frameworks.
- `ImageCache` and `ArchiveAdapter` are independent (no upward dependencies).
- `AppCore` may import `LibraryStore` and the leaf modules, but imports no UI
  framework — that is what makes it reachable from `swift test`.
- `LibraryServerAPI` is a leaf: both the server and the client depend on it,
  and it depends on neither.
- The App target is the only place SwiftUI and AppKit are imported.

This separation makes the StackroomFormat module reusable for CLI migration
tools, batch scripts, or alternative UIs (iPad in the future).
