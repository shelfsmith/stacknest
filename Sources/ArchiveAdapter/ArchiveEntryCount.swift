// SPDX-License-Identifier: MIT
import Foundation

/// アーカイブ内の画像エントリ数の計数結果。
///
/// `ArchiveListing`（列挙結果）と同じ理由で `truncated` を持つ: 破損等で計数が途中で
/// 打ち切られた場合、libarchive は打ち切り位置までの `count` しか返せず、「本来の総数」は
/// 持てない。`countImageEntries` は `listImageEntries` と同じ入力を数えるだけの経路なので、
/// 打ち切りの意味論も揃える（G26 Import gate fixup）。
public struct ArchiveEntryCount: Sendable, Equatable {
    public let count: Int
    public let truncated: Bool

    public init(count: Int, truncated: Bool) {
        self.count = count
        self.truncated = truncated
    }
}
