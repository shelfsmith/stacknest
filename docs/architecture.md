# Architecture

## Module graph

```
                 ┌──────────────┐
                 │   App/       │
                 │  (SwiftUI)   │
                 └──────┬───────┘
                        │ depends on
       ┌────────────────┼─────────────────┐
       ▼                ▼                 ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ LibraryStore │ │  ImageCache  │ │ArchiveAdapter│
│   (GRDB)     │ │  (ImageIO)   │ │ (libarchive) │
└──────┬───────┘ └──────────────┘ └──────────────┘
       │ depends on
       ▼
┌──────────────────┐
│ StackroomFormat  │
│  (PropertyList)  │
└──────────────────┘
```

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
- **App/** — SwiftUI macOS application target. Glues the four libraries into
  the user-facing experience: sidebar, browser, item grid, item detail,
  external helper launching.

## Strict layering

Lower layers do not import upper layers. Specifically:

- `StackroomFormat` has no SQLite, no SwiftUI, no AppKit dependencies.
- `LibraryStore` may import `StackroomFormat` but no UI frameworks.
- `ImageCache` and `ArchiveAdapter` are independent (no upward dependencies).
- The App target is the only place SwiftUI and AppKit are imported.

This separation makes the StackroomFormat module reusable for CLI migration
tools, batch scripts, or alternative UIs (iPad in the future).
