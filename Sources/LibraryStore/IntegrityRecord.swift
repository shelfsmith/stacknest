// SPDX-License-Identifier: MIT
import Foundation

/// 1 冊の整合性検査結果の判定値（spec §4.2）。
public enum IntegrityStatus: String, Codable, Sendable, CaseIterable {
    case ok            // 全エントリを問題なく読めた
    case damaged       // CRC 不一致、または途中で構造が壊れて読み進めない
    case empty         // 開けるが画像が 1 枚もない
    case missing       // ファイルが存在しない
    case unsupported   // 検査対象外（動画・EPUB/テキスト/PDF 等）
}

/// どちらの検査による結果か。
public enum IntegrityMethod: String, Codable, Sendable {
    case quick   // pages 未取得の候補を開いて分類（G27a）
    case full    // 全エントリの CRC 検証（G27b で使う。本フェーズでは書かない）
}

/// `book_integrity` の 1 行。
///
/// `prevStatus` / `prevCheckedAt` は 1 世代前の結果で、**upsert 時に DB 側が現在値から自動で
/// 退避する**（呼び出し側は nil を渡してよい。渡した値は無視される）。
/// これにより「元々壊れていた本」と「ディスク上で腐った本」を区別できる。
public struct IntegrityRecord: Sendable, Equatable {
    public let bookID: Int
    public let status: IntegrityStatus
    public let method: IntegrityMethod
    public let checkedAt: Int64          // Unix 秒
    public let fileSize: Int64?          // 検査時点のファイル同一性
    public let fileMtime: Double?
    public let entryCount: Int?
    public let badEntries: [String]      // 壊れたエントリ名（最大 maxBadEntries 件）
    public let prevStatus: IntegrityStatus?
    public let prevCheckedAt: Int64?

    /// bad_entries を無制限に保存すると 1 行が肥大するため上限を設ける。
    public static let maxBadEntries = 20

    public init(bookID: Int, status: IntegrityStatus, method: IntegrityMethod,
                checkedAt: Int64, fileSize: Int64?, fileMtime: Double?,
                entryCount: Int?, badEntries: [String],
                prevStatus: IntegrityStatus?, prevCheckedAt: Int64?) {
        self.bookID = bookID
        self.status = status
        self.method = method
        self.checkedAt = checkedAt
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.entryCount = entryCount
        self.badEntries = Array(badEntries.prefix(Self.maxBadEntries))
        self.prevStatus = prevStatus
        self.prevCheckedAt = prevCheckedAt
    }

    /// 前回 ok だったものが damaged になった＝ディスク上で劣化した疑い。
    public var isDegraded: Bool { prevStatus == .ok && status == .damaged }
}

/// 一覧シート／CLI が出す集計。
public struct IntegritySummary: Sendable, Equatable {
    public let checked: Int      // book_integrity に行がある本
    public let unchecked: Int    // まだ行が無い本
    public let damaged: Int
    public let degraded: Int     // prev_status='ok' かつ status='damaged'

    public init(checked: Int, unchecked: Int, damaged: Int, degraded: Int) {
        self.checked = checked
        self.unchecked = unchecked
        self.damaged = damaged
        self.degraded = degraded
    }
}
