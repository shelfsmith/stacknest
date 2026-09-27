[日本語](CONTRIBUTING.md) | [English](CONTRIBUTING.en.md)

# StackNest への貢献

個人プロジェクトです。外部からの貢献は歓迎しますが、メンテナンスに割ける時間は限られています。

## 開発環境

1. macOS 14 Sonoma 以降（Tahoe 26 推奨）
2. Xcode 26 以降（Swift 6.2 ツールチェイン）
3. `xcodegen`（`brew install xcodegen`）— `App/project.yml` から `App/StackNest.xcodeproj` を生成するために必要
4. 認証済みの `gh` CLI（メンテナのみ・リリース用）

## Xcode プロジェクトの生成

Xcode プロジェクトはリポジトリに**コミットされていません**。ローカルで生成してください:

```bash
xcodegen generate --spec App/project.yml
```

`App/project.yml` を編集したら再実行してください。CI はビルド前に自動で実行します。

## ワークフロー

1. `main` からブランチを切る
2. **失敗するテストを先に書く（TDD）**。production code は failing-test-first のカバレッジを必須とする
3. push 前に全テストと App ビルドを実行する:

```bash
# SPM テスト（StackroomFormat / LibraryStore / ImageCache / ArchiveAdapter）
swift test --parallel

# macOS App ビルド（Release は Universal、Debug は active arch）
xcodegen generate --spec App/project.yml
xcodebuild \
  -project App/StackNest.xcodeproj \
  -scheme StackNest \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

TDD 中の個別テスト絞り込み: `swift test --filter <SuiteName>`。

4. コミットメッセージは Conventional Commits 形式。本リポジトリで使う主な type:
   - `feat:` 新機能
   - `fix:` バグ修正
   - `refactor:` 挙動を変えないコード変更
   - `perf:` 性能改善
   - `chore:` リポジトリ整備
   - `docs:` ドキュメント
   - `ci:` CI / GitHub Actions
   - `test:` テストのみの変更
5. マージ時は squash

ビルド／テストコマンドの正は `.github/workflows/ci.yml` です。

インポータに大きな変更を加える前は、エンドツーエンドの取り込みを一度通しておくこと:

```bash
time swift run stackroom-import \
  --xml "$HOME/Library/Application Support/stackroom/Stackroom Library.xml" \
  --out /tmp/stackroom.sqlite \
  --force
sqlite3 /tmp/stackroom.sqlite "SELECT COUNT(*) FROM book"   # ≥ 10000
```

## 日英のローカライズ（必須）

StackNest の UI は日本語と英語に対応しています（macOS の言語設定に従います）。**画面・メッセージ・ヘルプ・Web・CLI／MCP の文言を足したり変えたりする変更には、同じ変更の中で英訳を付けてください。**英訳の無い日本語の文言は CI（`Scripts/l10n-lint.py --strict`）で落ちます。

- **原文は日本語**で、キーは日本語の文字列そのものです。
  - App（SwiftUI・AppKit）: `App/StackNest/Localizable.xcstrings` に `en` を足す。`String` で組み立てる文言は `String(localized: "…")`。
  - SPM のモジュール（AppCore・サーバ・CLI）: `L10n.text("…")`／`L10n.format("…%@…", 値)`／`L10n.plural("%lld …", count: n, n)`、辞書は `Sources/StackNestL10n/Tables/`。整数は `%lld` を使う（`%d` は 64 ビットの値を切り詰める）。
  - アプリ内ヘルプ: `App/StackNest/Help/HelpContent+ja.swift` と `+en.swift` を両方、同じ構造で直す。
  - Web: `t('…')`／`data-i18n` を使い、英訳は `Sources/LibraryServer/Resources/web/i18n-en.js`。
  - MCP（`mcp-stacknest/`）は英語で書く。
- **訳さないもの**: DB・設定・Finder タグ・ファイル名に保存する値、`--json` と API の出力、ログ、コメント。表示用の文字列で分岐・比較しないでください。
- 訳語と文体は [`docs/l10n-glossary.md`](docs/l10n-glossary.md) に従います（無い語を訳したら追記）。
- 確認:

```bash
STACKNEST_LANG=ja swift test
xcodebuild test -project App/StackNest.xcodeproj -scheme StackNest -destination 'platform=macOS' -testLanguage ja -testRegion JP
python3 Scripts/l10n-lint.py --strict --stringsdata-root <App の DerivedData>/Build/Intermediates.noindex/StackNest.build/Debug
node --test web-tests/*.mjs
```

英語の画面は `open StackNest.app --args -AppleLanguages '(en)'` で確かめられます。

## アーキテクチャ

モジュール境界と依存グラフは `docs/architecture.md` を参照してください。

## ライセンス

貢献することで、あなたの貢献が MIT ライセンスの下に置かれることに同意したものとみなします。
