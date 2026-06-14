[日本語](README.md) | [English](README.en.md)

# StackNest

[![CI](https://github.com/shelfsmith/stacknest/actions/workflows/ci.yml/badge.svg)](https://github.com/shelfsmith/stacknest/actions/workflows/ci.yml)

Swift ネイティブ、Apple Silicon 対応の画像ライブラリ（カタログ）マネージャです。オリジナルの
[Stackroom](https://aromaticsapp.blogspot.com/p/stackroom.html) のライブラリ XML を**取り込む（インポートする）**ことができます。

> ⚠️ **互換性についての注記:** StackNest が対応するのは Stackroom ライブラリ XML の**インポート（一方向の読み込み）だけ**です。StackNest 自身のライブラリ形式（`.stacknest`）は独自で、**Stackroom と相互互換ではありません**（Stackroom で開いたり書き戻したりはできません）。また StackNest は**カタログ**ソフトで、`.stacknest` はメタデータと表紙サムネの目録です。画像・本の実体ファイルはライブラリの外（元の場所）に置かれ、StackNest はそのパスを参照します。

> **Status:** アクティブ開発中。Stackroom 互換インポート＋ブラウズ／編集／検索／内蔵ビューワ／マルチライブラリ／ロック／重複検出／ラベルカスタマイズ／DB 予防保全・修復（Phase 2.9 まで完了）が動作。サーバー / クライアントによるリモート閲覧（Phase 4）は将来構想です。

![StackNest のメイン画面](docs/images/main-ui.png)

## これは何か

StackNest は、aroma / aromatics soft が開発した **Stackroom 2.1b** の書き出す
Apple Property List XML ライブラリファイルを読み込み、大規模な画像コレクション
（10,000 件以上で動作確認済み）をブラウズ・管理するモダンな macOS ネイティブ体験を提供します。

本プロジェクトは **aroma / aromatics soft とは無関係**です。Swift でゼロから書かれた
独立実装で、Stackroom のライブラリ XML を**取り込める**（インポート専用）だけで、形式互換ではありません。

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
- **重複検出**: 別ディレクトリにある同一内容の本を SHA-256 バイト一致で検出（＋ シリーズ + 巻数一致）。解決シートで「登録のみ削除」／「ファイルもゴミ箱へ」、グループ単位の無視に対応
- **ラベルカスタマイズ**: 内容系フィールド（ジャンル / ネタ / キーワード A / B / C）と bookType 6 種を per-library で任意名に変更でき、全表示箇所（列ヘッダ / ソート / Detail / スタンプ / フィルタ / スマートシェルフ）へ一貫反映
- **ビューワキー再割当**: 設定 ▸ キー で内蔵ビューワの全操作を任意キーへ再割当（競合は拒否・行ごと / 全体の既定に戻す・ヘルプ表は現在の割当を反映）
- **大規模ライブラリ性能**: 数千〜数万件規模でソートを最適化（ICU 照合キーの前計算によりリスト更新ごとの再ソートを高速化）
- **内蔵ビューワ**: 専用ウィンドウ／全画面で閲覧。zip/cbz/cbr/7z・フォルダ・単一画像・PDF を統一パイプラインで表示。フィット（=）／ピンチ・＋− ズーム／ドラッグでパン、左右ゾーン・矢印・Space でページ送り、数字 0–9 で位置ジャンプ（0=先頭〜9=90%）・Tab / ⇧Tab で複数ページスキップ。**見開き表示**（グローバル既定 ON/OFF ＋本ごと上書き、表紙独立・横長ページ自動単独 W）、**本ごとページ方向**（右→左／左→右、Detail で 2 択・ビューア内 r で切替）、**スライドショー**（自動進行 s）、**続きから読む**（本ごとに最終ページ・見開き設定を永続）、**巻末挙動**（停止／次の巻へ／ループ e）と前後巻ナビ（[ / ]）、**全画面で開く**設定、キー操作ヘルプ（? / h）。**操作キーは設定 ▸ キー で全面的に再割当可能**。下端にミニマル HUD（進行表示）。内蔵 / 外部ビューワは設定で切替
- **ファイル操作**: ライブラリへの追加 / 削除 / ⌫ 削除 / ⌘⌫ ゴミ箱 / ⇧⌘R リネーム / ⌘D ファイル移動 / 各種確認 dialog
- **キーボードナビ**: グリッド / リストの矢印・Shift+矢印（範囲選択）・⌘↑↓・Home/End・PageUp/Down・Enter で開く
- **グリッドサイズ**: per-library で永続化される grid item size slider
- **パスワードロック**: ライブラリごとに SHA-256 (salt 付き) でロック設定可能。Touch ID / Apple Watch による生体認証解錠にも対応
- **対応形式**: アーカイブ ZIP / CBZ / RAR / CBR / 7z（libarchive 経由）・PDF（PDFKit）。画像 JPEG / PNG / GIF / WebP / HEIC / HEIF / TIFF / AVIF（NSImage 経由）
- **初回起動ウィザード**: 初回起動時にページ送り式ウィザードで「画像の開き方（内蔵 / 外部ビューワ）→（内蔵選択時）ビューワ初期設定 → 最初のライブラリ（新規 / 開く / 取り込み）」を設定。設定 ▸ 一般 からいつでも再表示可能
- **インポート**: 既存 Stackroom ライブラリ XML から SQLite DB へ移行
- **リモート共有（サーバ）**: ライブラリを HTTP で配信（トークン認証・QR / NIC 選択 / IPv6・縮小配信・ロック庫 unlock 対応）。**Web ブラウザ**から閲覧（list / grid・FTS 検索・ソート・ページ送り）と **Web リーダー**（3 層先読み・見開き / 1 頁送り・続きから・読み方向の双方向即時同期）
- **ネイティブリモートクライアント**: 別 Mac の StackNest から別サーバへ接続して閲覧（接続 / 履歴・**フルブラウズ**＝サイドバー / ファセット / フィルタ / 詳細ペイン read-only・ページ / 無限スクロール切替・内蔵ビューワ・進捗のサーバ同期）
- **オフラインダウンロード**: リモートの本を選んでローカル保存し、**接続なし**で一覧・閲覧（続きから）。タイトル画面 / File メニューの「オフライン」から起動。**複数選択で一括ダウンロード / 一括削除**
- **リモート / オフライン巻送り**: 内蔵ビューワの前 / 次の巻がリモート（隣接巻をストリーム・未 DL 可）・オフライン（DL 済の連続巻）でも動作。読みかけの巻は「続き / 最初」を選択

## 動作環境

- macOS 14 Sonoma 以降（主要ターゲットは macOS 26 Tahoe）
- Apple Silicon ネイティブ（x86_64 向け Universal Binary も生成）
- ソースからビルドするには Xcode 26+

## インストール（リリース版）

リリース版は **CI で ad-hoc 署名された Universal ビルド**を配布します（Apple Developer 公証なし）。GitHub の [Releases](https://github.com/shelfsmith/stacknest/releases) から `StackNest.app`（zip）をダウンロードし、`/Applications` などへ展開してください。

ad-hoc 署名アプリは Gatekeeper にブロックされるため、**初回のみ**許可操作が必要です（2 回目以降は通常どおりダブルクリックで起動）。

> **重要（macOS 15 Sequoia 以降）:** macOS 15 以降は「右クリック →『開く』」での Gatekeeper 回避が**廃止**されました。未署名／ad-hoc 署名アプリは、いったんブロックされたあとに**システム設定から明示的に許可**する必要があります。

**方法 A（推奨・GUI / macOS 15・26 で確認）**
1. `StackNest.app` を `/Applications` に置き、ダブルクリックする（「開けません」ダイアログが出るので「完了」）。
2. **システム設定 → プライバシーとセキュリティ** を開き、下部の「セキュリティ」セクションに表示される
   「"StackNest" は…ブロックされました」の右の **「このまま開く」** をクリック。
3. 認証（Touch ID またはログインパスワード）を求められたら入力し、確認ダイアログで再度 **「このまま開く」**。

**方法 B（ターミナル）** — quarantine 属性を除去してから起動（システム設定の操作が不要）：
```bash
xattr -dr com.apple.quarantine /Applications/StackNest.app
```

> macOS 14 以前では「右クリック →『開く』」でも開けますが、macOS 15 以降では上記の方法 A（システム設定からの許可）または方法 B を使ってください。

> ⚠️ ad-hoc 署名は「正規の開発元」を保証しません。信頼できる入手元（本リポジトリの Releases）からのみ導入してください。本プロジェクトは Apple Developer 公証を行いません（ad-hoc 署名配布で確定）。自分でビルドする場合は下記「ビルド」を参照してください。

## リポジトリ構成

```
App/                  -- macOS App ターゲット（xcodegen 経由で生成、xcodeproj は gitignored）
Sources/
  StackroomFormat/    -- Stackroom ライブラリ XML/plist の読み取り（インポート用）
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

### リモート閲覧（共有・クライアント・オフライン）

StackNest は同じアプリが**サーバ（共有）**にも**クライアント**にもなります。別の Mac・iPhone・タブレットのブラウザから、自分のライブラリを閲覧できます。

**サーバ側（共有する）**
1. 共有したいライブラリを開き、ツールバーの**アンテナ（配信インジケータ）**または共有設定で**共有を ON** にします。
2. 表示される **URL / QR コード / アクセストークン**を接続側に渡します（NIC 選択・IPv6 対応）。ロック庫は接続側でパスワード unlock が必要です。
3. **セキュリティ:** ポートを直接インターネットに公開せず、**Tailscale 等の VPN 経由**での利用を推奨します（LAN 内利用が前提）。

**Web ブラウザから見る**
- 接続側のブラウザで共有 URL を開くと、list / grid・全文検索・ソート・ページ送りでブラウズでき、本を開くと Web リーダー（先読み・見開き / 1 頁送り・続きから・読み方向同期）で読めます。

**ネイティブクライアント（別 Mac の StackNest から）**
- タイトル画面（または File メニュー）の **「サーバに接続…」** から URL とトークンを入力して接続します。サイドバー / ファセット / フィルタ / 詳細ペイン（読み取り専用）のフルブラウズと内蔵ビューワで閲覧でき、読書進捗はサーバへ同期されます。

**オフライン（接続なしで読む）**
- 接続中に本を**右クリック →「ダウンロード」**でローカル保存します。**「選択」モードで複数選択 → 一括ダウンロード**も可能です（シリーズをファセット / 検索で絞って「すべて選択」が便利）。
- タイトル画面 / File メニューの **「オフライン（ダウンロード済み）」** から、**サーバに接続していなくても**ダウンロード済みの本を一覧・閲覧できます（続きから・巻送り対応）。不要になった本は「選択」モードで一括削除できます。

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

## ライブラリの自動バックアップ (Phase 2.8 以降)

クラウド同期下での DB 破損に備え、各 `.stacknest` ライブラリは編集のあったセッションを閉じるたびに、バンドル内 `Backups/` へ世代バックアップ（軽量なメタデータ DB のスナップショット）を自動保存します。閲覧のみで変更がなければ世代は増えません。

- 有効/無効と保持世代数（1〜20、既定 5）はライブラリ設定の「バックアップ」タブで変更できます。
- ライブラリを開くときに整合性チェック (`PRAGMA quick_check`) を行い、破損を検知すると「最新の正常なバックアップから復元しますか？」と案内します。
- バックアップからの復元ができない場合は、続けて**「.recover で修復を試す」**（アプリ内）を選べます。システムの `sqlite3 .recover` で可能な範囲のデータを救出し、復元できた本の件数を提示してから開きます（壊れた本体は `library.prerecover-*` / `library.corrupt-*` として残します）。
- それでも直らない場合や手動で古い世代へ戻したい場合は、[DB 復旧ガイド](docs/recovery-guide.md) を参照してください（手動 `sqlite3 .recover` 手順を含む）。

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
| **2.6c** | **初回起動ウィザード**（内蔵 / 外部ビューワ選択・内蔵ビューワ初期設定・最初のライブラリ作成・設定から再表示） | ✅ 完了 |
| 2.7 | ブラッシュアップ＆性能（重複検出・フィールド / bookType ラベル カスタマイズ・ソート最適化・ビューワキー再割当 UI・複数命名フォーマットプリセット） | ✅ 完了 |
| **2.8** | **ライブラリ保全**（リンク切れ再指定・DB 自動バックアップ＋整合性チェック・NFC 正規化修正） | ✅ 完了 |
| **2.9** | **DB 修復**（アプリ内 `.recover` による破損データ救出・救出件数提示） | ✅ 完了 |
| 4.0 | サーバー / クライアント（リモート閲覧・画面サイズに応じた画像配信） | 🔭 将来構想 |

凡例: ✅ 完了 / 🔄 進行中 / ⏳ 予定 / 🔭 将来構想

> Phase 3（安定版リリース儀式）は本プロジェクトの方針に合わないため解体し、アイコン / ブランディング等の達成項目を各 Phase へ吸収しました。

リリースごとの変更点は [CHANGELOG.md](CHANGELOG.md)（[English](CHANGELOG.en.md)）を参照してください。

## ライセンス

MIT — `LICENSE` を参照。

## 謝辞

- aroma 氏 / aromatics soft — オリジナル Stackroom の開発と、Swift での書き直しへの
  明示的な後押しに感謝します。
