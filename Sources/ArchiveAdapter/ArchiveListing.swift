// SPDX-License-Identifier: MIT
import Foundation

/// アーカイブ内エントリの列挙結果。
///
/// `truncated` は「破損等で列挙が途中で打ち切られた」ことを示す。libarchive は破損箇所で
/// `ARCHIVE_FATAL` を返し、**その先に何エントリあるかは分からない**。したがって
/// 「本来の総数」は持てず、持てるのは「読めた分」と「打ち切られたか」だけである。
public struct ArchiveListing: Sendable, Equatable {
    public let names: [String]
    public let truncated: Bool

    public init(names: [String], truncated: Bool) {
        self.names = names
        self.truncated = truncated
    }
}
