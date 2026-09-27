// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

/// G56-S1: データベースの破損チェックの結果を表示用の文字列にする（ローカルとリモートの両方で使う）。
enum IntegrityRowsText {
    /// G56 より前のサーバが返していた、訳済みの失敗の行。
    private static let legacyErrorRows: Set<String> = ["(エラー)", "(Error)"]  // l10n:ignore values returned by pre-G56 servers

    static func display(_ rows: [String]) -> String {
        rows.prefix(20).map { row in
            (row == IntegrityCheckDTO.errorRow || legacyErrorRows.contains(row)) ? String(localized: "(エラー)") : row
        }.joined(separator: "\n")
    }
}
