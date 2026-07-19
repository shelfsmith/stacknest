// SPDX-License-Identifier: MIT
import Foundation
import OSLog
import Carchive

/// ステートフルな順方向アーカイブリーダー（本 1 冊につき 1 インスタンス）。
///
/// 背景（G18 C5）: 旧経路 `LibarchiveCoverExtractor.extractByName` は **ページ取得のたびに
/// アーカイブを開き直し、先頭からそのエントリまで stream を読み飛ばす** ため、深いページほど
/// O(N) I/O（zip/rar/7z の streaming リーダーでは skip も圧縮データを実際に読み通す）。
/// 内蔵ビューアの矢印長押しで「常駐キャッシュを使い切った以降のページ」がこの O(N) 取得待ちに
/// なり、Apple Silicon でも滑らかにめくれない主因だった（cooViewer との差）。
///
/// 本クラスは **アーカイブを開いたまま物理順に前方ストリームし、通過した画像エントリを temp へ
/// 抽出キャッシュ（名前キー）** する。前方めくり（＝先読みも同じ順）はカーソルを進めるだけ＝
/// セッション通じてアーカイブを **1 パス** で読み、各エントリの抽出は高々 1 回。通過済みエントリは
/// 常にキャッシュ済みなので後方参照でも再オープン不要。
///
/// - actor で全アクセスを直列化（libarchive のハンドルは 1 本の cursor 状態を持つため）。
///   ビュー側の複数プリフェッチ Task が同時に呼んでも、順方向の 1 パスに集約される。
/// - 実行は actor executor（協調スレッドプール＝メインスレッド外）で走り、GUI を塞がない。
public actor SequentialArchiveExtractor {
    private let url: URL
    /// キャッシュ対象＝ページとして扱う画像エントリ名（`listImageEntries` と同一集合）。
    /// 非画像エントリはストリーム上でスキップし temp に残さない。
    private let imageNames: Set<String>
    private let tempDir: URL

    /// libarchive ハンドル。アクセスは actor が直列化する（deinit の解放のためだけ
    /// nonisolated(unsafe)＝実アクセスは全て actor 上なので安全）。
    private nonisolated(unsafe) var archive: OpaquePointer?
    private var opened = false
    private var atEOF = false
    /// 抽出済みエントリ名 → temp ファイル URL。
    private var extracted: [String: URL] = [:]

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "SequentialArchiveExtractor")

    public init(url: URL, imageNames: Set<String>) {
        self.url = url
        self.imageNames = imageNames
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacknest-arc-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        if let archive { archive_read_free(archive) }
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// 指定エントリ名のデータを返す。キャッシュ済みなら temp から読み、未取得なら現在の cursor から
    /// 物理順に前方ストリームし、通過した画像エントリを抽出キャッシュしつつ目的の名前まで進める。
    public func data(forName name: String) throws -> Data {
        if let fileURL = extracted[name] {
            return try Data(contentsOf: fileURL)
        }
        try openIfNeeded()
        while !atEOF {
            var entry: OpaquePointer?
            let r = archive_read_next_header(archive, &entry)
            if r == ARCHIVE_EOF { atEOF = true; break }
            if r != ARCHIVE_OK && r != ARCHIVE_WARN {
                throw ArchiveAdapterError.archiveUnreadable(url, reason: errorMessage())
            }
            guard let entry, let cName = archive_entry_pathname(entry) else {
                archive_read_data_skip(archive); continue
            }
            let entryName = String(cString: cName)
            // ページ集合外（ディレクトリ・非画像）はスキップして temp に残さない。
            guard imageNames.contains(entryName) else {
                archive_read_data_skip(archive); continue
            }
            let data = try readCurrentEntryData()
            let fileURL = tempDir.appendingPathComponent(UUID().uuidString)
            try data.write(to: fileURL, options: .atomic)
            extracted[entryName] = fileURL
            if entryName == name { return data }
        }
        // ここに来る＝要求された名前がアーカイブ内に見つからない（ページ集合と不整合）。
        throw ArchiveAdapterError.noImageEntry(url)
    }

    // MARK: - private

    private func openIfNeeded() throws {
        if opened { return }
        guard let a = archive_read_new() else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "archive_read_new failed")
        }
        archive_read_support_format_zip(a)
        archive_read_support_format_rar(a)
        archive_read_support_format_rar5(a)
        archive_read_support_format_7zip(a)
        archive_read_support_filter_all(a)
        let status = url.path.withCString { cPath in
            archive_read_open_filename(a, cPath, 16384)
        }
        if status != ARCHIVE_OK {
            let msg = errorMessage(a)
            archive_read_free(a)
            throw ArchiveAdapterError.archiveUnreadable(url, reason: msg.isEmpty ? "open failed" : msg)
        }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        archive = a
        opened = true
        atEOF = false
    }

    /// 現在のエントリの全データを読み切る（サイズ未知の format にも対応するため 0 が返るまでループ）。
    private func readCurrentEntryData() throws -> Data {
        var out = Data()
        let bufSize = 256 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                archive_read_data(archive, raw.baseAddress, bufSize)
            }
            if n < 0 {
                throw ArchiveAdapterError.archiveUnreadable(url, reason: errorMessage())
            }
            if n == 0 { break }
            buf.withUnsafeBytes { raw in
                out.append(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), count: n)
            }
        }
        return out
    }

    private func errorMessage(_ a: OpaquePointer? = nil) -> String {
        let handle = a ?? archive
        guard let handle, let cStr = archive_error_string(handle) else { return "" }
        return String(cString: cStr)
    }
}
