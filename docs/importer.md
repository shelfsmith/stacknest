# Stackroom Importer CLI

`stackroom-import` is the command-line tool that converts a Stackroom Library
XML file into a SQLite database for StackNest.

## Usage

```bash
stackroom-import --xml <path-to-Library.xml> --out <path-to-output.sqlite> [--force] [--quiet]
```

## Options

| Option | Required | Default | Description |
|---|---|---|---|
| `--xml` | yes | — | Path to Stackroom Library.xml |
| `--out` | yes | — | Path to output SQLite database |
| `--force` | no | false | Delete existing output DB before importing |
| `--quiet` | no | false | Suppress progress output |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | All items imported successfully |
| 1 | Imported with some skipped items (anomalies) |
| 2 | Fatal error (XML/DB I/O, schema migration, etc.) |

## Anomaly handling

The importer normalizes minor field-level variations transparently:
- `Unseen`: bool, int (≥1 = true), missing (false)
- `My Rate`: clamped to 0..5
- `Path`: optional (38% of real records lack it)

Items that fail dict-key integer validation or missing required fields are
**skipped** (not aborted) and reported in the import summary.

## Performance

Targets 10,000+ items in under 30 seconds on macOS 14+ Apple Silicon.

## In-app vs CLI

The CLI (`stackroom-import`) and the macOS app share the same `LibraryImporter` codepath. Either tool produces a SQLite database with identical schema. The defaults differ:

| | CLI | App |
|---|---|---|
| Output path | `--out` (required) | `~/Library/Application Support/StackNest/library.sqlite` (fixed) |
| Force replace | `--force` | always replaces (in-app re-import = overwrite) |
| Progress UI | stderr `\r` percent | SwiftUI ProgressView |
| Exit codes | 0 / 1 / 2 | (errors surfaced via alert) |

`thumbnails_directory_path` is set on import based on the XML's parent + `Stackroom Library/`. The app uses this to locate `<dir>/<id>/thumbnail.jpg` for grid display.
