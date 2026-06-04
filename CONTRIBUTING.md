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

## アーキテクチャ

モジュール境界と依存グラフは `docs/architecture.md` を参照してください。

## ライセンス

貢献することで、あなたの貢献が MIT ライセンスの下に置かれることに同意したものとみなします。
