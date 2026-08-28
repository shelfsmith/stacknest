// SPDX-License-Identifier: MIT
import Foundation
import StackroomFormat

extension BookRow {
    /// 命名フォーマットに渡すための `BookRecord` へ変換する。
    ///
    /// **`series` / `volume` を必ず渡すこと。**以前この変換は `BookFileRenameSheet` の中に
    /// private であり、両方を落としていた（トークンが無かったので気づけなかった）。
    public func toRecord() -> BookRecord {
        BookRecord(
            id: id,
            title: title,
            author: author,
            genre: genre,
            path: path,
            coverImageName: coverImageName,
            dateAdded: dateAdded,
            playDate: playDate,
            bookType: bookType,
            fileType: fileType,
            pages: pages,
            myRate: rating,
            unseen: unseen,
            keywordA: keywordA,
            keywordB: keywordB,
            keywordC: keywordC,
            neta: neta,
            series: series,
            volume: volume
        )
    }
}
