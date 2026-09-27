[日本語](CONTRIBUTING.md) | [English](CONTRIBUTING.en.md)

# Contributing to StackNest

This is a personal project. External contributions are welcome but maintenance
bandwidth is limited.

## Development setup

1. macOS 14 Sonoma+ (Tahoe 26 recommended)
2. Xcode 26+ with Swift 6.2 toolchain
3. `xcodegen` (`brew install xcodegen`) — required to generate `App/StackNest.xcodeproj` from `App/project.yml`
4. `gh` CLI authenticated (maintainers only, for releases)

## Generating the Xcode project

The Xcode project is **not** committed to the repository. Generate it locally:

```bash
xcodegen generate --spec App/project.yml
```

Re-run after editing `App/project.yml`. CI does this automatically before building.

## Workflow

1. Branch from `main`
2. Write the failing test first (TDD); production code must have failing-test-first coverage
3. Run all tests and the App build before pushing:

```bash
# SPM tests (StackroomFormat / LibraryStore / ImageCache / ArchiveAdapter)
swift test --parallel

# macOS App build (Universal in Release; per-arch active in Debug)
xcodegen generate --spec App/project.yml
xcodebuild \
  -project App/StackNest.xcodeproj \
  -scheme StackNest \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

For per-test filtering during TDD: `swift test --filter <SuiteName>`.

4. Use Conventional Commits for messages. Common types in this repo:
   - `feat:` new functionality
   - `fix:` bug fix
   - `refactor:` code change without behavior change
   - `perf:` performance improvement
   - `chore:` repo plumbing
   - `docs:` documentation
   - `ci:` CI / GitHub Actions
   - `test:` test-only changes
5. Squash on merge

`.github/workflows/ci.yml` is the canonical source of truth for build/test commands.

For a full end-to-end importer run before pushing significant Importer changes:

```bash
time swift run stackroom-import \
  --xml "$HOME/Library/Application Support/stackroom/Stackroom Library.xml" \
  --out /tmp/stackroom.sqlite \
  --force
sqlite3 /tmp/stackroom.sqlite "SELECT COUNT(*) FROM book"   # ≥ 10000
```

## Japanese and English localization (required)

StackNest's UI is available in Japanese and English (it follows the macOS language). **Any change that adds or edits user-facing text — App UI, messages, help, web UI, CLI/MCP output — must include the English translation in the same change.** Japanese text without English fails CI (`Scripts/l10n-lint.py --strict`).

- **Japanese is the source language**, and keys are the Japanese strings themselves.
  - App (SwiftUI / AppKit): add `en` to `App/StackNest/Localizable.xcstrings`. Build `String` values with `String(localized: "…")`.
  - SPM modules (AppCore, server, CLI): `L10n.text("…")` / `L10n.format("…%@…", value)` / `L10n.plural("%lld …", count: n, n)`, with dictionaries in `Sources/StackNestL10n/Tables/`. Use `%lld` for integers (`%d` truncates 64-bit values).
  - In-app help: edit both `App/StackNest/Help/HelpContent+ja.swift` and `+en.swift`, keeping the same structure.
  - Web: use `t('…')` / `data-i18n`, with the English in `Sources/LibraryServer/Resources/web/i18n-en.js`.
  - MCP (`mcp-stacknest/`) text is written in English.
- **Do not translate** values stored in the DB, settings, Finder tags or filenames, `--json`/API output, logs, or comments. Never branch on display strings.
- Follow [`docs/l10n-glossary.md`](docs/l10n-glossary.md) for terms and style (add new terms there).
- Checks:

```bash
STACKNEST_LANG=ja swift test
xcodebuild test -project App/StackNest.xcodeproj -scheme StackNest -destination 'platform=macOS' -testLanguage ja -testRegion JP
python3 Scripts/l10n-lint.py --strict --stringsdata-root <App DerivedData>/Build/Intermediates.noindex/StackNest.build/Debug
node --test web-tests/*.mjs
```

To see the English UI, run `open StackNest.app --args -AppleLanguages '(en)'`.

## Architecture

See `docs/architecture.md` for module boundaries and dependency graph.

## License

By contributing you agree your contributions are MIT licensed.
