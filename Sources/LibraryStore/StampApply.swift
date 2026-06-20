// SPDX-License-Identifier: MIT
import Foundation

/// 4.2c-6a: 一括スタンプ適用のコア（サーバ/テスト共用）。
/// 各 book の当該マルチ値フィールドへ apply=append（`addToBookField`）/ clear=NULL（`clearBookField`）を
/// 適用する。両 DB メソッドが NFC 正規化・重複 skip・列 whitelist を担うため、ここは薄いループに徹する。
/// 不正な field（スタンプ対象外）は `StampApplyError.invalidField`。戻り値=処理した book 件数。

public enum StampApplyError: Error, Equatable {
    case invalidField(String)
}

/// スタンプ対象として許可するマルチ値カラム（`StampField.dbColumn` 相当・author は対象外）。
private let stampAllowedColumns: Set<String> = ["genre", "neta", "keyword_a", "keyword_b", "keyword_c"]

@discardableResult
public func applyStampToBooks(db: Database, field: String, value: String?, clear: Bool, bookIDs: [Int]) throws -> Int {
    guard stampAllowedColumns.contains(field) else { throw StampApplyError.invalidField(field) }
    var updated = 0
    for id in bookIDs {
        if clear {
            try db.clearBookField(id: id, column: field)
            updated += 1
        } else {
            guard let v = value, !v.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            _ = try db.addToBookField(id: id, column: field, value: v)
            updated += 1
        }
    }
    return updated
}
