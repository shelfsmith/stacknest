// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import LibraryStore
import CoreGraphics

/// 4.2c-6b: リモート用の表紙ピッカー。エントリ一覧/プレビューはサーバ API（注入クロージャ）から取得。
/// G25b-2 P4: UI シェルは `CoverPickerSheet` と共有し、この型はサーバ経路の
/// `CoverPickerSource` を組み立てるだけ（ローカル専用 API には一切触れない）。
struct RemoteCoverPickerSheet: View {
    let book: BookRow
    let loadCandidates: () async -> [String]
    let loadEntryImage: (String) async -> NSImage?
    let onSelect: (String, CGRect?) -> Void

    var body: some View {
        CoverPickerSheet(book: book, source: source, onSelect: onSelect)
    }

    private var source: CoverPickerSource {
        CoverPickerSource(
            listEntries: {
                let names = await loadCandidates()
                // リモートは取得エラーを区別できない（クロージャは throw しない）ため、
                // 空リストはエラー表示に寄せる（従来挙動）。
                return (names, names.isEmpty ? "画像エントリが見つかりませんでした" : nil)
            },
            thumbnail: { entry in
                guard let img = await loadEntryImage(entry) else { return nil }
                return Image(nsImage: img)
            },
            preview: { entry in
                guard let img = await loadEntryImage(entry) else { return .cleared }
                return .image(img)
            }
        )
    }
}
