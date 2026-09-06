// SPDX-License-Identifier: MIT
import SwiftUI

/// アプリ内ヘルプページ。メニューバー「ヘルプ ▸ StackNest ヘルプ」(⌘?) から
/// `openWindow(id: "help")` で表示する独立ウィンドウ。
/// 外部 README へのリンクではなく、アプリ自身が操作リファレンスを内包する。
struct HelpView: View {
    private static let repoURL = "https://github.com/shelfsmith/stacknest"
    @State private var keyVersion = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading

                section("概要") {
                    para("StackNest は Apple Silicon ネイティブの画像ライブラリ管理アプリです。オリジナル Stackroom が書き出す Apple Property List XML ライブラリと互換性があり、大規模な画像・コミックコレクション（zip / cbz / cbr / 7z・フォルダ・単一画像・PDF）をブラウズ・管理します。")
                }

                section("ライブラリを始める") {
                    para("初回起動時（新規インストール直後）は初回ウィザードが画像の開き方と最初のライブラリを順に案内します。以降はタイトル画面から次を選べます:")
                    bullet("新しいライブラリを作成 — 任意の場所に空の `.stacknest` を作成")
                    bullet("既存のライブラリを開く — 既存の `.stacknest` を選択")
                    bullet("Stackroom Library から取り込む — Stackroom の `Stackroom Library.xml` を新規 `.stacknest` として保存")
                    para("起動時の挙動（タイトル画面 / 前回のライブラリ / 指定ライブラリ）は設定（⌘,）の「起動時」で切り替えます。各ライブラリは独立ウィンドウで同時に開けます。")
                }

                section("ブラウズ・検索・選択") {
                    keyRow("⇧/⌘ 表示切替・選択", "グリッド / リスト切替、矢印で移動、⇧+矢印で範囲選択、⌘↑↓ / Home / End / PageUp・Down、Enter で開く")
                    keyRow("検索", "ツールバーの検索バー（SQLite FTS5 全文検索）")
                    para("Browser ペインで属性カラム（ジャンル / 作者 / キーワード等の個別値）に絞り込み。スマートシェルフは条件式（N 条件 × AND/OR × マッチタイプ）で動的にコレクションを構成します。スタンプペインの chip で複数本に属性を一括付与できます。")
                }

                section("ファイル操作・メタデータ") {
                    keyRow("ライブラリから削除", "⌫")
                    keyRow("ゴミ箱へ移動", "⌘⌫")
                    keyRow("リネーム（トークン書式）", "⇧⌘R")
                    para("リネームのトークンには `@series` / `@volume` / `@keywordC` も使えます（巻数はシリーズ内で桁が揃います）。同じ処理を `stacknest-cli rename-files` と MCP からも呼べます（下の「コマンドライン / AI から操作」）。")
                    keyRow("ファイル移動", "⌘D")
                    keyRow("レート設定", "⌘0–5")
                    keyRow("未読 / 既読トグル", "⌘T")
                    keyRow("このライブラリの設定", "⇧⌘,")
                    keyRow("アプリ設定", "⌘,")
                }

                section("表紙を変える") {
                    para("各本の表紙は詳細ペインで変更できます。表紙の上で右クリック（コンテキストメニュー）から:")
                    bullet("表紙を編集 — アーカイブ内の任意ページを選び、表示範囲をクロップ")
                    bullet("外部画像を表紙に設定… — 任意の画像ファイルを選ぶ（または詳細ペインの表紙へ画像を **ドラッグ&ドロップ**）→ クロップして設定")
                    bullet("自動に戻す — 手動表紙を外し、先頭ページからの自動表紙へ")
                    bullet("表紙を再生成 — 現在のファイルから表紙を作り直す（**1 冊単位**）。ファイルの中身を差し替えたのに表紙が古いままのときに使います。外部画像を表紙にしている本では選べません（上書きしない規約のため）。リンク切れの再指定（再リンク）を行った場合は、表紙とページ数が自動で更新されます。")
                    para("表紙の変更は**見た目（サムネイル）のみ**で、アーカイブ本体・元ファイルは変更しません。リモート（編集トークン）でも同様に操作でき、共有元やほかのクライアントで表紙が変わった場合は一覧のリロード / 再接続で追従します。")
                    para("ライブラリ全体の表紙をまとめて作り直したい場合は、このライブラリの設定（⇧⌘,）の「表紙を再生成」を使います（進捗表示付き）。")
                }

                section("内蔵ビューア") {
                    para("本を開くと専用ウィンドウ（または全画面）で表示します。キー操作:")
                    viewerKeyTable
                    para("見開き、ページ方向、続きから読む、巻末挙動は本ごとに永続化されます。内蔵 / 外部ビューアの切替は 設定 ▸ 表示 ▸ 画像ビューア ▸ ビューア で行います。")
                    para("**ルーペ**はカーソル位置を拡大して見せます。ON の間は**スクロールで倍率**が変わり（現在倍率は HUD に出ます）、**形（円 / 正方形）と大きさ（小 / 中 / 大）**は 設定 ▸ 表示 で選べ、倍率もそこで確認・既定に戻せます。拡大部分はその場で再デコードするので、拡大しても粗くなりません。")
                    para("**「複数ビューアの起動を許可」**（設定 ▸ 表示）は既定はオフで、同じ本を二重に開かず、別の本を開くと**1つのビューアに保たれます**（開いている本を再度開くと前面化）。オンにすると**別の本は別ウィンドウで開けます**（どちらでも同じ本は1つに集約されます）。")
                }

                section("EPUB を読む（ベータ）") {
                    para("EPUB を取り込むと表紙とメタデータ（題名・著者・言語・綴じ方向）が EPUB から入ります。ダブルクリックで開けます。**ベータ**です: 読めますが、下記の制約の範囲で挙動が固まっていません。")
                    bullet("**テキストの EPUB** — 専用の窓で縦組み・ルビ・見開き・右綴じ。← → Space PageUp / PageDown ↑ ↓ でページ送り、Home / End で章の先頭 / 末尾。文字倍率は ⌘+ / ⌘− / ⌘0（設定として保存）。読書位置は本ごとに保存されます。")
                    bullet("**全ページが画像の EPUB（漫画）** — EPUB リーダーではなく画像ビューアで開きます（見開き・右綴じ・ズーム・ルーペ・巻送りがそのまま効きます）。")
                    bullet("**綴じ方向** — 取り込み時に EPUB の規定を本へ反映します。規定の無い本はグローバル既定に従い、右クリックでの上書きが優先されます。")
                    bullet("**リモート / Web / オフライン** — Web リーダー（ブラウザ・iPad / iPhone）とリモート書庫（別 Mac の StackNest）でも読め、読書位置は Mac・Web・リモートで共有されます。ダウンロード済みの EPUB はオフラインでも読めます（オフラインの位置はサーバとは同期しません）。")
                    bullet("**制約（ベータの理由）** — 混在本の挿絵は見開きになりません。本文検索・目次・注釈はありません。Kobo 向け CSS を持つ本など、レイアウトに違和感が出る EPUB があります。Web の EPUB はオフライン保存できません。")
                    para("EPUB の解析と Mac での表示には Washi、Web リーダーには foliate-js を使っています（下の「オープンソースと謝辞」）。")
                }

                section("外部ビューア") {
                    para("外部ビューアを使う場合は 設定 ▸ 表示 ▸ 画像ビューア（⌘,）で「選択…」からアプリ（cooViewer、Avian、プレビュー 等）を指定します。設定後はグリッドで本をダブルクリックすると外部ビューアで開きます。拡張子ごとに別ビューアを割り当てることもできます。")
                }

                section("リモートで使う（共有・クライアント・オフライン）") {
                    para("同じ StackNest がサーバ（共有）にもクライアントにもなります。別の Mac や iPhone / タブレットのブラウザから自分のライブラリを閲覧できます。")
                    bullet("共有する — ライブラリのツールバーのアンテナ（配信インジケータ）で共有を ON。サーバ設定の「共有トークン」で相手ごとに権限（閲覧/編集/管理者）と見せるライブラリを分けたトークンを作り、その URL / QR / トークンを接続側へ渡します。ロック庫は接続側でパスワード unlock が必要。")
                    bullet("Web で見る — 接続側のブラウザで共有 URL を開く（list / グリッド・全文検索・ソート・ページ送り、Web リーダーで見開き / 1 頁送り・続きから・読み方向の双方向同期）。ページは**ドラッグでめくれます**（指の動きに追従し、離すと慣性で送り先が決まります）。リーダーから一覧へ戻ると、**スクロール位置と絞り込みが保たれます**。")
                    bullet("ネイティブクライアント — タイトル画面（または File メニュー）の「サーバに接続…」で URL とトークンを入力。サイドバー / ファセット / フィルタ / 詳細のフルブラウズと内蔵ビューアで閲覧、読書進捗はサーバへ同期。**編集権限の共有トークンなら詳細ペインで編集**できます（メタデータの単一 / 複数一括編集、スタンプ付与 / 定義編集、表紙編集〔アーカイブ内ページ選択 / クロップ / 外部画像を D&D・メニューで表紙に〕、読み方向。閲覧のみのトークンは読み取り専用）。")
                    bullet("オフライン — 接続中に本を右クリック →「ダウンロード」（「選択」モードで複数選択 → 一括ダウンロードも可）。タイトル画面 / File メニューの「オフライン（ダウンロード済み）」から、サーバに接続していなくても一覧・閲覧（続きから・巻送り）。不要分は「選択」モードで一括削除。")
                    bullet("追加 / 削除（権限次第）— 管理者トークンならリモートのまま本を削除。複数冊をまとめて削除すると**進捗が表示され、途中で中止**できます（中止すると残りの未処理分が止まります）。閲覧のみのトークンでもレート・未読は共有評価 / 閲覧状態として変更できます。")
                    bullet("キャッシュと追従 — リモートのページ / 表紙は端末にディスク永続キャッシュされ、再接続 / 再起動後も高速。ビューアのプログレスバーにキャッシュ済み範囲を帯で表示します。サーバ側で表紙が変わった場合は一覧のリロード / 再接続で追従します（手動キャッシュ削除は不要）。キャッシュの上限 / 保持期間 / 使用量 / クリアは 設定 ▸ 表示 ▸ リモートキャッシュ で管理します。")
                    para("セキュリティ: ポートを直接インターネットに公開せず、Tailscale 等の VPN 経由・LAN 内での利用を推奨します（DB・画像本体は暗号化されません）。")
                }

                section("監視フォルダで自動取込") {
                    para("指定したフォルダを監視し、そこに置かれたアーカイブ / 画像フォルダを**自動でライブラリへ取り込み**ます。設定 ▸ 取り込み（監視フォルダ）でフォルダを追加し、フォルダごとに命名プリセットを割り当てられます。初回はプレビューで確認でき、取込結果はライブラリ窓の上端にバナーで表示されます（**取り込めなかったファイルがあるときは自動で消えず**、「詳細」からどのファイルがなぜ失敗したかを確認できます。× で閉じられます）。自動分類（bookType）・厚さ閾値はライブラリごとに上書きできます（「StackNest 設定の値に従う」/ 個別指定）。")
                    para("**サブフォルダの扱い**はフォルダごとに選べます:")
                    bullet("サブフォルダを取り込まない — 直下のファイルだけを対象にします")
                    bullet("サブフォルダを1冊として取り込む — 直下のサブフォルダ 1 つを 1 冊として扱います（孫フォルダには降りません）。直下の素ファイルも個別に取り込みます")
                    bullet("サブフォルダの中も個別に取り込む — 再帰的に走査し、中のファイルをそれぞれ 1 冊として取り込みます")
                    para("本は移動せず、その場所を参照して追加されます（追加のみ）。NAS など共有ボリュームでは反映まで最大 60 秒かかります。")
                }

                section("Finder タグと同期する") {
                    para("macOS の **Finder タグ**と、庫のメタデータ項目 1 つを**双方向に同期**します。庫の設定 ▸ 取り込み ▸ **Finder タグの同期**で項目を選ぶと有効になります（既定は「同期しない」＝何も起きません）。")
                    para("Finder で付けたタグは選んだ項目に入り、StackNest で編集した値は Finder のタグになります。**どちらかで消したタグは、もう一方からも消えます**（前回同期した値を覚えているため。単純な合併だと消したタグが復活してしまいます）。")
                    para("同期が走るのは**庫を開いたとき**と、**手動で再照合したとき**です。再照合は、ライブラリ窓のツールバーの循環矢印ボタン（同期を有効にしている庫でだけ出ます）か、庫の設定の「今すぐ再照合」から。")
                    bullet("**同期できる項目** — ジャンル / 作者 / ネタ / キーワード A・B・C の 6 つ。**シリーズは同期できません**（単一値の項目のため、区切り文字を含む名前が Finder 上で 2 つのタグに割れてしまいます）。")
                    bullet("**タグの色は保たれます** — StackNest 側に色の概念はありませんが、既にある色を消すことはしません。")
                    bullet("**名前に「, 」を含むタグ**は、項目の区切り文字と衝突するため同期しません。その旨をバナーで知らせます。")
                    bullet("**Spotlight 索引が無効なボリューム**では、Finder → StackNest の方向が動きません（`mdutil -s <ボリューム>` で確認できます）。この場合もバナーで知らせ、StackNest → Finder の書き戻しは動きます。")
                    para("**規模に依存しません。** タグの付いた項目だけを Spotlight で引くので、12,000 冊の庫でも 0.4 秒程度で終わります。")
                }

                section("コマンドライン / AI から操作（ローカルアクセス）") {
                    para("GUI を介さず、コマンドラインや AI エージェントからライブラリを操作できます。設定 ▸ 一般 ▸ ローカルアクセス で有効化します（127.0.0.1 限定）。")
                    bullet("CLI — 同梱の `stacknest-cli` で 一覧 / 追加 / 削除 / メタ編集 / 棚 CRUD / 監視 / ロック / 取り込み / 再リンク / 重複 / 共有トークン / スタンプ / ラベル を操作（`stacknest-cli --help`）。パスワードは stdin 入力。Finder タグの再照合は `stacknest-cli finder-tags resync`。")
                    bullet("MCP — `mcp-stacknest`（Model Context Protocol サーバ）を登録すると、対応する AI エージェントから同等の操作ができます。")
                    bullet("API ドキュメント — ローカルエンドポイントは API 専用で、ブラウザでルート（/）を開くと Redoc（OpenAPI 3.1）の API リファレンスが表示されます。")
                }

                section("ファイルの破損チェック") {
                    para("蔵書のアーカイブが壊れていないかを検査します。File メニュー ▸ **ファイルの破損チェック…** で専用ウィンドウが開きます（スキャン中も他の操作やアプリの終了を妨げません）。")
                    bullet("**未検査をスキャン** — まだ調べていない本だけを検査します。")
                    bullet("**全件やり直し** — すべて調べ直します。**蔵書規模によっては数時間〜数十時間**かかるため、開始前に確認します。")
                    bullet("**破損のみ再検査** — 前回破損と判定された本だけを調べ直します（ファイルを差し替えた後などに）。")
                    para("検査は 2 段階です。**簡易チェック**はファイルの有無・サイズ・開けるかを見ます。**詳細（CRC）チェック**はアーカイブ内の各エントリを実際に読んで検証するため確実ですが時間がかかります。**いつでも中断でき、途中までの結果は残ります。**")
                    para("**前回は正常だったのに今回破損した本（劣化）を一覧の先頭に表示**します。バックアップから戻すべき本を見つけやすくするためです。")
                    para("対象は .zip / .cbz / .rar / .cbr / .7z と単独画像です。フォルダ・動画・PDF / EPUB は CRC を持たないため「対象外」と記録します（壊れていないという意味ではありません）。")
                    para("**リモート接続でも使えます。** ただし長時間かかるジョブのため、**開始には管理者権限のトークンが必要**です（解錠済みかつ admin のときだけメニューが有効になります）。リモートではサーバ機のファイルを指すため「Finder で表示」は使えません。")
                    para("コマンドラインからは `stacknest-cli integrity scan / status / list / full-scan / job-status / cancel` で同じ操作ができます。")
                }

                section("ライブラリのロック") {
                    para("各ライブラリにパスワードロックを設定できます（SHA-256 + salt、Touch ID / Apple Watch 解錠対応）。これは偶発的アクセスを防ぐ簡易ロックで、DB・画像本体は暗号化されません。強い秘匿性が必要なら FileVault 等を併用してください。")
                    para("施錠したライブラリは、**ウィンドウを閉じたあと開き直すときに改めて解錠が必要**です（起動時の「続きから読む」で復帰する場合も解錠を求めます）。リモート接続でも同様です。解錠のパスワード試行には回数制限があり、続けて失敗すると一時的にロックアウトされます。")
                    para("**ロックが既にある場合、パスワードの変更にも解除にも現在のパスワードが必要です。** 解錠したまま席を離れても、第三者がパスワードを書き換えて乗っ取ることはできません（新規に設定する場合は不要です）。")
                    para("パスワードを忘れた場合のリカバリーはありません。`.stacknest/library.sqlite` の `library_settings` から lock 関連の行を削除すると解除できます（詳細は README）。")
                }

                section("リンク") {
                    link("ソースコード / README（GitHub）", Self.repoURL)
                    link("オリジナル Stackroom（aroma / aromatics soft）", "https://aromaticsapp.blogspot.com/p/stackroom.html")
                    para("StackNest は aroma / aromatics soft とは無関係の独立した互換実装です。")
                }

                section("オープンソースと謝辞") {
                    para("StackNest は次のオープンソースソフトウェアを使っています（ライセンス全文は各リポジトリ、または同梱の LICENSE を参照）。")
                    link("Washi — EPUB の解析と Mac での表示（縦組み・ルビ・見開き）。MIT / shunnag", "https://github.com/shunnag/Washi")
                    link("foliate-js — Web リーダーの EPUB 表示。MIT / John Factotum", "https://github.com/johnfactotum/foliate-js")
                    link("zip.js — Web リーダーで EPUB を展開。BSD-3-Clause / Gildas Lormeau", "https://github.com/gildas-lormeau/zip.js")
                    link("GRDB.swift — SQLite。MIT / Gwendal Roué", "https://github.com/groue/GRDB.swift")
                    link("Hummingbird — 内蔵サーバ。Apache-2.0", "https://github.com/hummingbird-project/hummingbird")
                    link("swift-argument-parser — コマンドライン。Apache-2.0 / Apple", "https://github.com/apple/swift-argument-parser")
                    link("libarchive — ZIP / RAR / 7z の読み込み。BSD-2-Clause", "https://www.libarchive.org")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 580, idealWidth: 660, minHeight: 540, idealHeight: 740)
        .onAppear { keyVersion += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .viewerKeyBindingsChanged)) { _ in keyVersion += 1 }
    }

    // MARK: - Building blocks

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("StackNest ヘルプ").font(.system(size: 22, weight: .bold))
            Text("操作リファレンス").font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
    }

    private func para(_ text: String) -> some View {
        Text(.init(text)).font(.system(size: 12.5)).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.system(size: 12.5))
            Text(.init(text)).font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keyRow(_ action: String, _ keys: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(keys).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(action).font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 内蔵ビューアのキー表は ViewerHelpOverlayView と単一ソースを共有する。
    private var viewerKeyTable: some View {
        let grouped = ViewerHelpOverlayView.grouped
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(grouped, id: \.section) { group in
                Text(group.section).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.secondary)
                ForEach(group.rows, id: \.action) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Text(row.keys).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .frame(width: 300, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(row.action).font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .id(keyVersion)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    private func link(_ label: String, _ urlString: String) -> some View {
        Group {
            if let url = URL(string: urlString) {
                Link(label, destination: url).font(.system(size: 12.5))
            } else {
                Text(label).font(.system(size: 12.5))
            }
        }
    }
}
