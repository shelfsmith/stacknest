// SPDX-License-Identifier: MIT
import Foundation
import OSLog
import Carchive

/// アーカイブ 1 冊分の CRC 検証結果。
///
/// `badEntries` にはアーカイブ内エントリ名のみを入れる（**libarchive のエラー文字列は
/// 絶対に含めない** — `archive_error_string()` は権限拒否・ファイル不在で絶対パスを
/// 返すことが実測されている。これは `LibarchiveCoverExtractor` の呼び出し元
/// `QuickIntegrityScanner.probeFailureReason` が同じ理由で生文字列を捨てているのと同じ規律）。
public struct ArchiveVerifyResult: Sendable, Equatable {
    /// ディレクトリ以外の全エントリ数（画像に限らない）。
    public let entryCount: Int
    /// 画像拡張子（`LibarchiveCoverExtractor.imageExtensions` と同じ集合）を持つエントリ数。
    public let imageCount: Int
    /// CRC 不一致 (または読み取り自体の失敗) だったエントリの名前一覧。
    public let badEntries: [String]
    /// アーカイブ構造が途中で壊れていた、または中断されたために全件を検証しきれなかった。
    public let truncated: Bool

    public init(entryCount: Int, imageCount: Int, badEntries: [String], truncated: Bool) {
        self.entryCount = entryCount
        self.imageCount = imageCount
        self.badEntries = badEntries
        self.truncated = truncated
    }
}

/// アーカイブの全エントリを実際に読み、libarchive に CRC を検証させる（Phase G27b Task 1）。
///
/// **雛形は `LibarchiveCoverExtractor.enumerateImageEntries`（同じ開き方・同じフォーマット登録・
/// 同じ打ち切り規則）。唯一の違いは `archive_read_data_skip` の代わりに `archive_read_data` で
/// データ本体を読むこと** — libarchive はこのときだけ CRC を検証し、不一致なら負値を返す
/// （正常なエントリは正のバイト数を返し続け、最後に 0 を返す。controller が実機で確認済み）。
public enum ArchiveIntegrityVerifier {
    // LibarchiveCoverExtractor.imageExtensions は private なのでここで同じ集合を持つ
    // （画像判定の意味は揃える必要があるが、verify は画像に限らず全エントリを検証する）。
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp",
        "heic", "heif", "tiff", "tif", "avif"
    ]

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "ArchiveIntegrityVerifier")

    /// 1MB スクラッチバッファ。読んだ内容は破棄する（CRC 検証だけが目的で、データそのものは不要）。
    private static let bufferSize = 1 << 20

    /// アーカイブを開き、ディレクトリ以外の全エントリを実際に読んで CRC を検証する。
    ///
    /// - `isCancelled` は **エントリ単位** で確認する（1 冊 ~5 秒。冊単位のチェックでは
    ///   31 時間規模のフルスキャンを打ち切るのに粗すぎる）。中断された場合、検証未完了
    ///   という意味で `truncated: true` を返す（G26 の規則同様、完了していない結果を
    ///   「クリーン」として報告しないため）。
    /// - アーカイブ構造が途中で壊れている場合も、集められた分を `truncated: true` で返す
    ///   （throw しない）。ただし 1 件も読めないまま破綻した場合は throw する
    ///   （`enumerateImageEntries` と同じ「0 ページの本として黙って開かせない」規律）。
    /// - open 自体が失敗した場合（非アーカイブファイル・権限拒否等）は throw する。
    public static func verify(url: URL, isCancelled: () async -> Bool = { false }) async throws -> ArchiveVerifyResult {
        guard let archive = archive_read_new() else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "archive_read_new failed")
        }
        defer { archive_read_free(archive) }

        archive_read_support_format_zip(archive)
        archive_read_support_format_rar(archive)
        archive_read_support_format_rar5(archive)
        archive_read_support_format_7zip(archive)
        archive_read_support_filter_all(archive)

        let status = url.path.withCString { cPath in
            archive_read_open_filename(archive, cPath, 16384)
        }
        if status != ARCHIVE_OK {
            let msg = errorMessage(archive)
            throw ArchiveAdapterError.archiveUnreadable(url, reason: msg.isEmpty ? "open failed" : msg)
        }

        var entryCount = 0
        var imageCount = 0
        var badEntries: [String] = []
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        var entry: OpaquePointer?
        while true {
            // エントリ単位の中断確認（次のヘッダを読む/読まないの境界で見る）。
            if await isCancelled() {
                return ArchiveVerifyResult(entryCount: entryCount, imageCount: imageCount,
                                           badEntries: badEntries, truncated: true)
            }

            let r = archive_read_next_header(archive, &entry)
            if r == ARCHIVE_EOF { break }
            if r != ARCHIVE_OK && r != ARCHIVE_WARN {
                // G26 の規則: 構造破綻で途中打ち切り。集めた分を truncated=true で返す。
                // 1 件も集まっていなければ「0 ページの本」として黙って開かせないため throw する。
                if entryCount == 0 {
                    let msg = errorMessage(archive)
                    throw ArchiveAdapterError.enumerationFailed(url, reason: msg.isEmpty ? "read header failed" : msg)
                }
                return ArchiveVerifyResult(entryCount: entryCount, imageCount: imageCount,
                                           badEntries: badEntries, truncated: true)
            }
            guard let entry = entry, let cName = archive_entry_pathname(entry) else {
                archive_read_data_skip(archive)
                continue
            }
            let name = String(cString: cName)
            if name.hasSuffix("/") {
                // ディレクトリエントリにはデータが無い。skip して次へ。
                archive_read_data_skip(archive)
                continue
            }

            entryCount += 1
            let ext = (name as NSString).pathExtension.lowercased()
            if Self.imageExtensions.contains(ext) {
                imageCount += 1
            }

            // ここが LibarchiveCoverExtractor.enumerateImageEntries との唯一の違い:
            // archive_read_data_skip の代わりに実データを読む。libarchive はこの読み取りで
            // CRC を検証し、不一致その他の読み取り失敗は負値を返す。
            var bad = false
            readLoop: while true {
                let got = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                    archive_read_data(archive, rawBuf.baseAddress, rawBuf.count)
                }
                if got == 0 { break readLoop }      // このエントリを読み切った
                if got < 0 { bad = true; break readLoop }  // CRC 不一致等
            }
            if bad {
                badEntries.append(name)
            }
        }

        return ArchiveVerifyResult(entryCount: entryCount, imageCount: imageCount,
                                   badEntries: badEntries, truncated: false)
    }

    /// libarchive のエラー文字列を安全に読む（nil なら空文字列）。
    /// **呼び出し側は絶対にこの文字列を `ArchiveVerifyResult` へ入れてはいけない**
    /// （throw される `ArchiveAdapterError` の `reason` にのみ使う。open 失敗経路の
    /// throw はそもそも `badEntries` を経由しない）。
    private static func errorMessage(_ archive: OpaquePointer) -> String {
        guard let cStr = archive_error_string(archive) else { return "" }
        return String(cString: cStr)
    }
}
