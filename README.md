[日本語](README.md) | [English](README.en.md)

# StackNest

[![CI](https://github.com/shelfsmith/stacknest/actions/workflows/ci.yml/badge.svg)](https://github.com/shelfsmith/stacknest/actions/workflows/ci.yml)

Swift ネイティブ、Apple Silicon 対応の画像ライブラリマネージャです。オリジナルの
[Stackroom](https://aromaticsapp.blogspot.com/p/stackroom.html) ライブラリフォーマットと互換性があります。

> **Status:** プレアルファ（Phase 2.6c — 初回起動ウィザード：内蔵 / 外部ビューワ選択・内蔵ビューワ初期設定・最初のライブラリ作成。内蔵ビューワ拡張：見開き・本ごとページ方向・スライドショー・続きから読む・全画面・HEIC/AVIF 対応。ライブラリ CRUD / ロック / スタンプ / マルチ値フィルタ / 全文検索 / スマートシェルフ / グリッド・リストのキーボードナビ）

## これは何か

StackNest は、aroma / aromatics soft が開発した **Stackroom 2.1b** の書き出す
Apple Property List XML ライブラリファイルを読み込み、大規模な画像コレクション
（10,000 件以上で動作確認済み）をブラウズ・管理するモダンな macOS ネイティブ体験を提供します。

本プロジェクトは **aroma / aromatics soft とは無関係**です。Swift でゼロから書かれた
独立した互換実装です。

## なぜこのプロジェクトがあるか

オリジナル Stackroom（最終リリース: 2.1b Build 198、2019年）は x86_64 専用バイナリで、
arm64 ネイティブサポートがありません。Rosetta 2 での動作は継続していますが、長期的には
ネイティブ書き直しが必要になります。

aroma 氏（原作者）は 2019 年頃、5ch 新・Mac 板のスレッド（[egg.5ch.net/test/read.cgi/mac/1391446507](https://egg.5ch.net/test/read.cgi/mac/1391446507/)）にて次のように述べています：

> ライブラリファイルはただの XML だし、その気があるなら **たぶん Swift で
> 一から作ったほうが早いくらい** だと思います。

本プロジェクトはこの明示的な推奨に従っています。オリジナル Stackroom のバイナリ、
ソースコード、アイコン、UI スクリーンショット、Sparkle スタイルのブランディングアセットは
**再配布していません**。ディスク上のライブラリフォーマットのみを観察から再実装しています。

- aroma 氏のオリジナル Stackroom: <https://aromaticsapp.blogspot.com/p/stackroom.html>
- aroma 氏のリリースブログ: <https://aromaticsapp.blogspot.com/>

## 主な機能

- **ライブラリブラウズ**: グリッド / リスト 2 ビュー、Browser pane（属性別カラムフィルタ）、Detail pane（メタデータ編集）
- **検索**: ツールバーの検索バー + SQLite FTS5 による全文検索
- **マルチ値フィールド**: ジャンル / 作者 / キーワード A / B / C はカンマ区切りで複数値を保持、Browser pane で個別値ごとに絞り込み可能
- **スマートシェルフ**: 条件式（N 条件 × AND/OR × 4 マッチタイプ）で動的にコレクションを構成。Apple Mail 風の条件エディタ。インポートした Stackroom スマートプレイリストも動的評価
- **スタンプペイン**: ユーザ定義の chip（5 列、消去 / 値 / 新規追加）で複数本に一括属性付与
- **内蔵ビューワ**: 専用ウィンドウ／全画面で閲覧。zip/cbz/cbr/7z・フォルダ・単一画像・PDF を統一パイプラインで表示。フィット（=）／ピンチ・＋− ズーム／ドラッグでパン、左右ゾーン・矢印・Space でページ送り、数字 0–9 で位置ジャンプ（0=先頭〜9=90%）・Tab / ⇧Tab で複数ページスキップ。**見開き表示**（グローバル既定 ON/OFF ＋本ごと上書き、表紙独立・横長ページ自動単独 W）、**本ごとページ方向**（右→左／左→右、Detail で 2 択・ビューア内 r で切替）、**スライドショー**（自動進行 s）、**続きから読む**（本ごとに最終ページ・見開き設定を永続）、**巻末挙動**（停止／次の巻へ／ループ e）と前後巻ナビ（[ / ]）、**全画面で開く**設定、キー操作ヘルプ（? / h）。下端にミニマル HUD（進行表示）。内蔵 / 外部ビューワは設定で切替
- **ファイル操作**: ライブラリへの追加 / 削除 / ⌫ 削除 / ⌘⌫ ゴミ箱 / ⇧⌘R リネーム / ⌘D ファイル移動 / 各種確認 dialog
- **キーボードナビ**: グリッド / リストの矢印・Shift+矢印（範囲選択）・⌘↑↓・Home/End・PageUp/Down・Enter で開く
- **グリッドサイズ**: per-library で永続化される grid item size slider
- **パスワードロック**: ライブラリごとに SHA-256 (salt 付き) でロック設定可能。Touch ID / Apple Watch による生体認証解錠にも対応
- **対応形式**: アーカイブ ZIP / CBZ / RAR / CBR / 7z（libarchive 経由）・PDF（PDFKit）。画像 JPEG / PNG / GIF / WebP / HEIC / HEIF / TIFF / AVIF（NSImage 経由）
- **初回起動ウィザード**: 初回起動時にページ送り式ウィザードで「画像の開き方（内蔵 / 外部ビューワ）→（内蔵選択時）ビューワ初期設定 → 最初のライブラリ（新規 / 開く / 取り込み）」を設定。設定 ▸ 一般 からいつでも再表示可能
- **インポート**: 既存 Stackroom ライブラリ XML から SQLite DB へ移行

## 動作環境

- macOS 14 Sonoma 以降（主要ターゲットは macOS 26 Tahoe）
- Apple Silicon ネイティブ（x86_64 向け Universal Binary も生成）
- ソースからビルドするには Xcode 26+

## リポジトリ構成

```
App/                  -- macOS App ターゲット（xcodegen 経由で生成、xcodeproj は gitignored）
Sources/
  StackroomFormat/    -- ライブラリ plist の読み書き（互換レイヤー）
  LibraryStore/       -- SQLite（GRDB）リポジトリ、Migration、FTS5、マルチ値正規化
  ImageCache/         -- サムネイル描画 / キャッシュ
  ArchiveAdapter/     -- libarchive 経由の ZIP / CBZ / RAR / CBR / 7z 読み込み
  AppCore/            -- アプリレベルのロジック（LibrarySettings, AppPreferences, LibraryLock, エラー型、外部ビューワ起動）— テスト容易性のため SwiftUI 非依存
  StackroomImportCLI/ -- インポータ実行ファイル（swift run stackroom-import）
Tests/                -- Swift Testing モジュール（swift-testing）
docs/                 -- アーキテクチャ、設計メモ、smoke checklist
```

## ビルド

### SPM ライブラリと CLI

```bash
swift build
swift test
swift run stackroom-import --xml "$HOME/Library/Application Support/stackroom/Stackroom Library.xml" --out /tmp/stackroom.sqlite --force
```

### macOS App

`xcodeproj` は gitignore されているため、まず `xcodegen` で生成します。

```bash
cd App && xcodegen && cd ..
xcodebuild \
  -project App/StackNest.xcodeproj \
  -scheme StackNest \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Universal Binary（arm64 + x86_64）でのリリースビルド：

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

`xcodegen` 実行後は `App/StackNest.xcodeproj` を Xcode で開くこともできます。

CLI インポータのリファレンスは `docs/importer.md` を参照してください。

## 使い方

アプリのビルドまたは `xcodebuild` の実行後、macOS アプリを起動します：

```bash
open ~/Library/Developer/Xcode/DerivedData/StackNest-*/Build/Products/Debug/StackNest.app
```

**初回起動時**（新規インストールで設定なし）は初回起動ウィザードが表示され、画像の開き方と最初のライブラリを順に設定します。2 回目以降やライブラリ未選択時はタイトル画面が表示され、次の 3 つの選択肢を提示します：

- **新しいライブラリを作成**: 任意の場所に空の `.stacknest` bundle を作成して開く
- **既存のライブラリを開く**: 既存の `.stacknest` bundle を選択して開く
- **Stackroom Library から取り込む**: aroma 氏のオリジナル Stackroom が出力する `Stackroom Library.xml` を読み込み、新規 `.stacknest` bundle として保存

### マルチライブラリ対応

各 `.stacknest` bundle は独立したライブラリ（SQLite DB + assets を含む macOS bundle）で、それぞれ独立した window で同時に開けます。同じライブラリを 2 回開こうとすると既存 window が前面に来ます（`OpenLibraryRegistry` による二重 open 防止）。

起動モードはアプリ設定（`⌘,`）の「起動時」で切替可能です：

- **タイトル画面を表示**（default）
- **前回開いていたライブラリを開く**: 終了時に open していた全 library が再度開く
- **指定ライブラリを毎回開く**: 設定で指定した特定 library のみ毎回開く

### 外部ビューワの設定

既定では本は**内蔵ビューワ**で開きます。内蔵 / 外部の切替は **設定 ▸ 表示 ▸ 画像ビューワ ▸ ビューワ** で行います。外部ビューワを使う場合は **設定 ▸ 表示 ▸ 画像ビューワ**（`⌘,`）で外部ビューワを設定してください。
「選択…」をクリックして画像ビューワアプリ（cooViewer、Avian、プレビュー 等）を選んでください。
設定しない場合、システムの Archive Utility が `.zip` を展開するだけになります。
選択した外部ビューワは `UserDefaults` を通じて起動間で保持されます。

設定済みであれば、グリッドで本をダブルクリックするとファイル（またはカバー画像）が
直接選択した外部ビューワで開きます。

### CLI からのインポート

タイトル画面の「Stackroom Library から取り込む」と同じ DB は、コマンドラインから `swift run stackroom-import` で生成することもできます（`docs/importer.md` 参照）。生成された SQLite DB を `.stacknest` bundle 内に配置して、「既存のライブラリを開く」から開けます。

## ライブラリのロック (Phase 2.5b 以降)

各 `.stacknest` ライブラリにはパスワードロックを設定できます。Touch ID / Apple Watch 連携にも対応しています。

### パスワードを忘れたとき

リカバリー手段は提供していません。ロックは「簡易的に他者からの偶発的アクセスを防ぐ」目的の機能で、暗号化はされていません。パスワードを忘れて開けなくなったライブラリは、以下の手順で **DB を直接編集することで解除** できます。

```bash
sqlite3 /path/to/MyLibrary.stacknest/library.sqlite \
  "DELETE FROM library_settings WHERE key IN ('lock_password_hash', 'lock_password_salt', 'lock_use_biometric');"
```

実行後はロックなし状態になり、StackNest から再度開けるようになります。必要に応じて File menu「このライブラリの設定…」(⇧⌘,) から再設定してください。

注意点:
- ロックは平文 hash + salt の SHA-256 で保護されているのみで、ライブラリ DB / 画像ファイル本体は暗号化されていません
- 強い秘匿性が必要な情報は別の手段 (Disk encryption, FileVault 等) で保護してください

## ロードマップ

開発は段階的フェーズで進めています。要約：

| フェーズ | 内容 | 状況 |
|---|---|---|
| 2.1 | Stackroom XML インポータ（CLI + SQLite/GRDB） | ✅ 完了 |
| 2.2 | グリッド / アイコン表示・サムネイル・アーカイブ読み込み | ✅ 完了 |
| 2.3 | サイドバー（ライブラリ / お気に入り / 最近）・シェルフ・詳細ペイン | ✅ 完了 |
| 2.4 | リスト表示・ツールバー / ファセットフィルタ・FTS5 検索・編集 | ✅ 完了 |
| 2.5 | マルチライブラリ・ファイル CRUD・表紙編集・Undo・ロック・命名・自動分類・PDF 取込 | ✅ 完了 |
| 2.5k | グリッド / リストのキーボードナビゲーション | ✅ 完了 |
| **2.6a** | **スマートシェルフ MVP**（条件式コレクション） | ✅ 完了 |
| **2.6b** | **内蔵ビューワ コアMVP**（フルスクリーン・フィット / ズーム / パン・ページ送り・PDF / アーカイブ / フォルダ / 単一画像） | ✅ 完了 |
| **2.6b-2** | **内蔵ビューワ拡張**（見開き表示・本ごとページ方向・スライドショー自動進行・続きから読む・巻末挙動 次の巻 / ループ・全画面で開く・HEIC / HEIF / TIFF / AVIF 対応） | ✅ 完了 |
| **2.6c** | **初回起動ウィザード**（内蔵 / 外部ビューワ選択・内蔵ビューワ初期設定・最初のライブラリ作成・設定から再表示） | ✅ 完了（本リリース） |
| 2.7 | ブラッシュアップ＆性能（大規模最適化・重複検出・ラベルカスタマイズ・90°回転・ビューワのキー全カスタマイズ UI 等） | ⏳ 予定 |
| 3.0 | 安定版リリース | ⏳ 予定 |
| 4.0 | サーバー / クライアント（リモート閲覧・画面サイズに応じた画像配信） | 🔭 将来構想 |

凡例: ✅ 完了 / ⏳ 予定 / 🔭 将来構想

## ライセンス

MIT — `LICENSE` を参照。

## 謝辞

- aroma 氏 / aromatics soft — オリジナル Stackroom の開発と、Swift での書き直しへの
  明示的な後押しに感謝します。
