// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

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
                    para("表紙の変更は**見た目（サムネイル）のみ**で、アーカイブ本体・元ファイルは変更しません。リモート（編集トークン）でも同様に操作でき、共有元やほかのクライアントで表紙が変わった場合は一覧のリロード / 再接続で追従します。")
                }

                section("内蔵ビューワ") {
                    para("本を開くと専用ウィンドウ（または全画面）で表示します。キー操作:")
                    viewerKeyTable
                    para("見開き・ページ方向・続きから読む・巻末挙動は本ごとに永続化されます。内蔵 / 外部ビューワの切替は 設定 ▸ 表示 ▸ 画像ビューワ ▸ ビューワ で行います。")
                    para("**「複数ビューアの起動を許可」**（設定 ▸ 表示）は既定オフ＝同じ本を二重に開かず、別の本を開くと**1つのビューアに保たれます**（開いている本を再度開くと前面化）。オンにすると**別の本は別ウィンドウで開けます**（どちらでも同じ本は1つに集約されます）。")
                }

                section("外部ビューワ") {
                    para("外部ビューワを使う場合は 設定 ▸ 表示 ▸ 画像ビューワ（⌘,）で「選択…」からアプリ（cooViewer、Avian、プレビュー 等）を指定します。設定後はグリッドで本をダブルクリックすると外部ビューワで開きます。拡張子ごとに別ビューワを割り当てることもできます。")
                }

                section("リモートで使う（共有・クライアント・オフライン）") {
                    para("同じ StackNest がサーバ（共有）にもクライアントにもなります。別の Mac やスマホ・タブレットのブラウザから自分のライブラリを閲覧できます。")
                    bullet("共有する — ライブラリのツールバーのアンテナ（配信インジケータ）で共有を ON。サーバ設定の「共有トークン」で相手ごとに権限（閲覧/編集/管理者）と見せるライブラリを分けたトークンを作り、その URL / QR / トークンを接続側へ渡します。ロック庫は接続側でパスワード unlock が必要。")
                    bullet("Web で見る — 接続側のブラウザで共有 URL を開く（list / グリッド・全文検索・ソート・ページ送り、Web リーダーで見開き / 1 頁送り・続きから・読み方向の双方向同期）。")
                    bullet("ネイティブクライアント — タイトル画面（または File メニュー）の「サーバに接続…」で URL とトークンを入力。サイドバー / ファセット / フィルタ / 詳細のフルブラウズと内蔵ビューワで閲覧、読書進捗はサーバへ同期。**編集権限の共有トークンなら詳細ペインで編集**＝メタデータの単一 / 複数一括編集・スタンプ付与 / 定義編集・表紙編集（アーカイブ内ページ選択 / クロップ / 外部画像を D&D・メニューで表紙に）・読み方向（閲覧のみのトークンは読み取り専用）。")
                    bullet("オフライン — 接続中に本を右クリック →「ダウンロード」（「選択」モードで複数選択 → 一括ダウンロードも可）。タイトル画面 / File メニューの「オフライン（ダウンロード済み）」から、サーバに接続していなくても一覧・閲覧（続きから・巻送り）。不要分は「選択」モードで一括削除。")
                    bullet("追加 / 削除（権限次第）— 管理者トークンならリモートのまま本を削除。閲覧のみのトークンでもレート・未読は共有評価 / 閲覧状態として変更できます。")
                    bullet("キャッシュと追従 — リモートのページ / 表紙は端末にディスク永続キャッシュされ、再接続 / 再起動後も高速。ビューアのプログレスバーにキャッシュ済み範囲を帯で表示します。サーバ側で表紙が変わった場合は一覧のリロード / 再接続で追従します（手動キャッシュ削除は不要）。キャッシュの上限 / 保持期間 / 使用量 / クリアは 設定 ▸ 表示 ▸ リモートキャッシュ で管理します。")
                    para("セキュリティ: ポートを直接インターネットに公開せず、Tailscale 等の VPN 経由・LAN 内での利用を推奨します（DB・画像本体は暗号化されません）。")
                }

                section("監視フォルダで自動取込") {
                    para("指定したフォルダを監視し、そこに置かれたアーカイブ / 画像フォルダを**自動でライブラリへ取り込み**ます。設定 ▸ 取り込み（監視フォルダ）でフォルダを追加し、フォルダごとに命名プリセットを割り当てられます。初回はプレビューで確認でき、取込結果はライブラリ窓に要約バナーで表示されます。自動分類（bookType）・厚さ閾値はライブラリごとに上書きできます（「StackNest 設定の値に従う」/ 個別指定）。")
                }

                section("コマンドライン / AI から操作（ローカルアクセス）") {
                    para("GUI を介さず、コマンドラインや AI エージェントからライブラリを操作できます。設定 ▸ 一般 ▸ ローカルアクセス で有効化します（127.0.0.1 限定）。")
                    bullet("CLI — 同梱の `stacknest-cli` で 一覧 / 追加 / 削除 / メタ編集 / 棚 CRUD / 監視 / ロック / 取り込み / 再リンク / 重複 / 共有トークン / スタンプ / ラベル を操作（`stacknest-cli --help`）。パスワードは stdin 入力。")
                    bullet("MCP — `mcp-stacknest`（Model Context Protocol サーバ）を登録すると、対応する AI エージェントから同等の操作ができます。")
                    bullet("API ドキュメント — ローカルエンドポイントは API 専用で、ブラウザでルート（/）を開くと Redoc（OpenAPI 3.1）の API リファレンスが表示されます。")
                }

                section("ライブラリのロック") {
                    para("各ライブラリにパスワードロックを設定できます（SHA-256 + salt、Touch ID / Apple Watch 解錠対応）。これは偶発的アクセスを防ぐ簡易ロックで、DB・画像本体は暗号化されません。強い秘匿性が必要なら FileVault 等を併用してください。")
                    para("パスワードを忘れた場合のリカバリーはありません。`.stacknest/library.sqlite` の `library_settings` から lock 関連の行を削除すると解除できます（詳細は README）。")
                }

                section("リンク") {
                    link("ソースコード / README（GitHub）", Self.repoURL)
                    link("オリジナル Stackroom（aroma / aromatics soft）", "https://aromaticsapp.blogspot.com/p/stackroom.html")
                    para("StackNest は aroma / aromatics soft とは無関係の独立した互換実装です。")
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

    /// 内蔵ビューワのキー表は ViewerHelpOverlayView と単一ソースを共有する。
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
