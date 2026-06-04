// SPDX-License-Identifier: MIT
import SwiftUI

/// アプリ内ヘルプページ。メニューバー「ヘルプ ▸ StackNest ヘルプ」(⌘?) から
/// `openWindow(id: "help")` で表示する独立ウィンドウ。
/// 外部 README へのリンクではなく、アプリ自身が操作リファレンスを内包する。
struct HelpView: View {
    private static let repoURL = "https://github.com/shelfsmith/stacknest"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading

                section("概要") {
                    para("StackNest は Apple Silicon ネイティブの画像ライブラリ管理アプリです。オリジナル Stackroom が書き出す Apple Property List XML ライブラリと互換性があり、大規模な画像・コミックコレクション（zip / cbz / cbr / 7z・フォルダ・単一画像・PDF）をブラウズ・管理します。")
                }

                section("ライブラリを始める") {
                    para("初めて起動したとき（新規インストール直後）は、初回ウィザードが画像の開き方と最初のライブラリを順に案内します。以降はタイトル画面から次を選べます:")
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

                section("内蔵ビューワ") {
                    para("本を開くと専用ウィンドウ（または全画面）で表示します。キー操作:")
                    viewerKeyTable
                    para("見開き・ページ方向・続きから読む・巻末挙動は本ごとに永続化されます。内蔵 / 外部ビューワの切替は 設定 ▸ 表示 ▸ 画像ビューワ ▸ ビューワ で行います。")
                }

                section("外部ビューワ") {
                    para("外部ビューワを使う場合は 設定 ▸ 表示 ▸ 画像ビューワ（⌘,）で「選択…」からアプリ（cooViewer、Avian、プレビュー 等）を指定します。設定後はグリッドで本をダブルクリックすると外部ビューワで開きます。拡張子ごとに別ビューワを割り当てることもできます。")
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
        VStack(alignment: .leading, spacing: 5) {
            ForEach(ViewerHelpOverlayView.rows, id: \.action) { row in
                HStack(alignment: .top, spacing: 12) {
                    Text(row.keys).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .frame(width: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.action).font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
