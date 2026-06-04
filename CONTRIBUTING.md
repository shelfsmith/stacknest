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

## Architecture

See `docs/architecture.md` for module boundaries and dependency graph.

## License

By contributing you agree your contributions are MIT licensed.
