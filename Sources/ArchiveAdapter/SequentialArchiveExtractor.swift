// SPDX-License-Identifier: MIT
import Foundation
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
    /// セキュリティ: 1 エントリあたりの読み取り累積サイズ上限（decompression-bomb / OOM 対策）。
    /// 既定は `ArchiveEntrySizeLimit.maxEntryBytes`。テストで小さい値を注入できるよう引数化している。
    private let maxEntryBytes: Int
    /// G64: tar を歩く仕事の上限（開き直すたびに数え直す）。
    private let walkLimits: TarWalkLimits
    /// G64: gzip で包んだ tar を読んでよいか（足したアーカイブの拡張子のときだけ true）。
    private let allowsCompressedTar: Bool
    private var walkBudget: TarWalkBudget?

    /// libarchive ハンドル。アクセスは actor が直列化する（deinit の解放のためだけ
    /// nonisolated(unsafe)＝実アクセスは全て actor 上なので安全）。
    private nonisolated(unsafe) var archive: OpaquePointer?
    private var opened = false
    private var atEOF = false
    /// 抽出済みエントリ名 → temp ファイル URL。
    private var extracted: [String: URL] = [:]
    /// 中身を読めなかったエントリ（CRC の不一致・伸長の失敗・1 エントリの上限超え）。以後の前方ストリームでは取り出さずに
    /// 読み飛ばす（`archive_read_data_skip`）。頼まれたときだけ、そのページの失敗として改めて読む（読めたら外す ―― NAS の
    /// 一時的な読み取りの失敗で、読めるページを読めないままにしない）。
    private var unreadable = Set<String>()
    /// 読めないエントリを越えるための開き直しの上限（1 回の `data(forName:)` の中で）。開き直すのはハンドルが使えなく
    /// なったとき（`ARCHIVE_FATAL`）だけで、壊れたエントリが多い書庫で開き直しを際限なく繰り返さないため。
    static let maxBadEntryReopens = 4
    /// `readCurrentEntryData` が最後に失敗したときの `archive_read_data` の値（負の状態）。自前の上限で断ったときは nil。
    private var lastDataStatus: Int?

    /// 目的でないエントリの中身を読めなかった（`streamForward` の中だけで使う）。
    private struct EntryUnreadable: Error {
        let name: String
        let underlying: any Error
    }

    public init(url: URL, imageNames: Set<String>, maxEntryBytes: Int = ArchiveEntrySizeLimit.maxEntryBytes,
                walkLimits: TarWalkLimits = .standard, allowsCompressedTar: Bool = false) {
        self.url = url
        self.imageNames = imageNames
        self.maxEntryBytes = maxEntryBytes
        self.walkLimits = walkLimits
        self.allowsCompressedTar = allowsCompressedTar
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stacknest-arc-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        if let archive { archive_read_free(archive) }
        // G19 review Important #4: temp ディレクトリ削除は「セッション中に抽出した全ページ」の再帰削除に
        // なり得る（tier3/全ページ先読み時は 1 冊分）。deinit は最後の強参照が切れたスレッドで走り、
        // それが巻スワップ/ウィンドウクローズ時に MainActor になり得る（`content` は @MainActor 保持）。
        // 同期の再帰削除をメインで走らせると「メインスレッドを止めない」という本フェーズの目的に反する。
        // → tempDir をローカルに退避し、削除だけをバックグラウンド（detached・優先度 utility）へ逃がす。
        // archive ハンドルの解放は軽量なので同期のまま。
        let dir = tempDir
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// 指定エントリ名のデータを返す。キャッシュ済みなら temp から読み、未取得なら現在の cursor から
    /// 物理順に前方ストリームし、通過した画像エントリを抽出キャッシュしつつ目的の名前まで進める。
    ///
    /// 耐障害性（review Important 対応）:
    /// - **キャンセル**: 走査ループ先頭で `Task.checkCancellation()`。取り消し時はハンドルを
    ///   **エントリ境界で保持したまま** 抜ける（カーソルは有効＝次要求が続きから進める。破棄しない）。
    /// - **読み取りエラー**: ハンドルを捨てて 1 回だけ再オープン再試行（破損エントリ以降が本全体で
    ///   全滅するのを防ぎ、旧 stateless の per-page 独立性を回復）。
    /// - **目的でないエントリの中身が読めない**（CRC の不一致など。一覧はヘッダしか読まないので、一覧では見えない）:
    ///   そのエントリを `unreadable` に記録し、その場で（ハンドルが使えなくなったときは開き直して）先へ進む。以後そのエントリは
    ///   読み飛ばす。以前は、壊れたエントリを
    ///   通るたびに失敗して、それより後の未取得のページがどれも読めなかった（HTTP では 500）。壊れたページそのものは失敗のまま。
    /// - **EOF まで未発見**: 外部でファイルが差し替わった等に備え 1 回だけ再オープンして再走査。
    public func data(forName name: String) throws -> Data {
        if let fileURL = extracted[name] {
            return try Data(contentsOf: fileURL)
        }
        // 前に中身を読めなかったページ: カーソルはもうその先にあるので、先に頭から開き直す（そのままだと EOF まで残りを
        // 全部取り出してから開き直していた）。開き直して読んでも失敗なら、もう一度は開き直さない（同じ失敗を繰り返すだけ）。
        var badEntryReopens = 0
        let reopenedFirst = unreadable.contains(name)
        if reopenedFirst { resetHandle() }
        do {
            if let data = try streamForwardPastBadEntries(to: name, reopens: &badEntryReopens) { return data }
        } catch is CancellationError {
            throw CancellationError()          // カーソル有効のまま（次要求が続きから進める）
        } catch ArchiveAdapterError.archiveUnreadable(let u, let reason)
                    where reason == TarWalkBudget.exceededReason || reason == TarWalkBudget.overrunReason {
            // G64: 上限超過は何度やっても同じ。ハンドルを捨てて再試行すると上限までの歩きを繰り返すだけなので、そのまま投げる。
            throw ArchiveAdapterError.archiveUnreadable(u, reason: reason)
        } catch {
            if reopenedFirst { throw error }
            resetHandle()                      // 破損等: ハンドルを捨てる
            if let data = try? streamForwardPastBadEntries(to: name, reopens: &badEntryReopens) { return data }  // 再オープンして 1 回だけ再試行
            throw error
        }
        // EOF まで見つからず: ファイル差し替え等を想定して 1 回だけ再オープン再走査。
        resetHandle()
        if let data = try streamForwardPastBadEntries(to: name, reopens: &badEntryReopens) { return data }
        throw ArchiveAdapterError.noImageEntry(url)
    }

    /// 試験用: 取り出して temp に置いたページの数と、ハンドルを開き直した回数。
    var extractedCountForTesting: Int { extracted.count }
    private(set) var resetCountForTesting = 0

    // MARK: - private

    /// `streamForward` を、目的でないエントリの中身が読めずにハンドルが使えなくなったら（`ARCHIVE_FATAL`）、開き直して
    /// 続けて試す（`maxBadEntryReopens` 回まで）。開き直しても、読めないエントリは読み飛ばすので伸長しない（zip は位置を
    /// 移すだけ）。ハンドルがまだ使えるとき（警告・そのエントリだけの失敗・自前の上限）は `streamForward` がその場で先へ進む。
    /// `reopens` は 1 回の `data(forName:)` の中で数える(再試行・EOF の再走査をまたいで共有する。2 回目のレビュー L-2: 以前は呼ぶたびに
    /// 数え直し、1 回の頼みで開き直しが最大 10 回 ―― tar では歩く量の上限の 10 倍 ―― になりえた)。
    private func streamForwardPastBadEntries(to name: String, reopens: inout Int) throws -> Data? {
        while true {
            do {
                return try streamForward(to: name)
            } catch let bad as EntryUnreadable {
                unreadable.insert(bad.name)
                guard reopens < Self.maxBadEntryReopens else { throw bad.underlying }
                reopens += 1
                // libarchive のハンドルは中身の読み取りに失敗すると使えないことがある（FATAL）ので、捨てて開き直す。
                resetHandle()
            }
        }
    }

    /// 現在の cursor から物理順に前方ストリームし、`name` を見つけたらそのデータを返す。
    /// EOF まで見つからなければ nil。読み取りエラーは throw。既抽出エントリは再抽出せずスキップ
    /// （再オープン後の重複抽出＝temp リークを防ぐ）。
    private func streamForward(to name: String) throws -> Data? {
        try openIfNeeded()
        while !atEOF {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let r = archive_read_next_header(archive, &entry)
            if r == ARCHIVE_EOF { atEOF = true; return nil }
            // G64: tar を歩く量の上限を超えたら、ヘッダが読めなくなったのと同じに扱う。
            if let archive, walkBudget?.exceeds(archive, header: r, entry: entry) == true {
                throw ArchiveAdapterError.archiveUnreadable(url, reason: TarWalkBudget.exceededReason)
            }
            if r != ARCHIVE_OK && r != ARCHIVE_WARN {
                throw ArchiveAdapterError.archiveUnreadable(url, reason: errorMessage())
            }
            guard let entry, let cName = archive_entry_pathname(entry) else {
                archive_read_data_skip(archive); continue
            }
            let entryName = String(cString: cName)
            // 既抽出（再オープン後の再遭遇）: 再抽出しない。対象ならキャッシュから返す。
            if let existing = extracted[entryName] {
                archive_read_data_skip(archive)
                if entryName == name { return try Data(contentsOf: existing) }
                continue
            }
            // ページ集合外（ディレクトリ・非画像）はスキップして temp に残さない。
            guard imageNames.contains(entryName) else {
                archive_read_data_skip(archive); continue
            }
            // 前に中身を読めなかったエントリは、目的でなければ読み飛ばす（目的なら、そのページの失敗として改めて読む）。
            if entryName != name, unreadable.contains(entryName) {
                archive_read_data_skip(archive); continue
            }
            let data: Data
            do {
                data = try readCurrentEntryData(entry: entry)
            } catch ArchiveAdapterError.archiveUnreadable(let u, let reason)
                        where reason == TarWalkBudget.exceededReason || reason == TarWalkBudget.overrunReason {
                // G64: tar を歩く量の上限は書庫全体の話。エントリを越えても同じなので、そのまま投げる。
                throw ArchiveAdapterError.archiveUnreadable(u, reason: reason)
            } catch {
                unreadable.insert(entryName)
                // 目的のページそのものは失敗として返す（次に頼まれたら頭から開き直して読む ―― `data(forName:)`）。
                guard entryName != name else { throw error }
                // ハンドルが使えなくなったときだけ開き直す（`streamForwardPastBadEntries`）。それ以外は、このエントリの
                // 残りを次のヘッダの読みが飛ばすので、その場で先へ進む（開き直すと、そこまでの読み飛ばしをやり直す）。
                if lastDataStatus == Int(ARCHIVE_FATAL) { throw EntryUnreadable(name: entryName, underlying: error) }
                continue
            }
            unreadable.remove(entryName)
            let fileURL = tempDir.appendingPathComponent(UUID().uuidString)
            try data.write(to: fileURL, options: .atomic)
            extracted[entryName] = fileURL
            if entryName == name { return data }
        }
        return nil
    }

    /// libarchive ハンドルを解放し、次回 `openIfNeeded()` で頭から開き直せる状態に戻す。
    /// 抽出済み temp キャッシュ（`extracted`）は保持する（再オープンで再抽出しないため）。
    private func resetHandle() {
        resetCountForTesting += 1
        if let archive { archive_read_free(archive) }
        archive = nil
        opened = false
        atEOF = false
    }

    private func openIfNeeded() throws {
        if opened { return }
        guard let a = archive_read_new() else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "archive_read_new failed")
        }
        LibarchiveFormats.enable(a, for: url, allowsCompressedTar: allowsCompressedTar)
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
        walkBudget = TarWalkBudget(url: url, limits: walkLimits)
    }

    /// 現在のエントリの全データを読み切る（サイズ未知の format にも対応するため 0 が返るまでループ）。
    ///
    /// セキュリティ: `archive_entry_size` は自己申告値で信頼できないため事前チェックせず、
    /// 実際に読み取った累積バイト数を毎チャンク後にチェックする（decompression-bomb / OOM 対策）。
    /// 上限超過時は `out` を捨てて即 throw — それ以上の蓄積・確保を行わない。
    private func readCurrentEntryData(entry: OpaquePointer) throws -> Data {
        // G64: tar は出てきた量を申告サイズでも縛る（既存の上限に加えて。zip 系は nil＝今のまま）。
        let producedLimit = archive.flatMap { TarWalkBudget.producedLimit($0, entry: entry) }
        lastDataStatus = nil
        var out = Data()
        let bufSize = 256 * 1024
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = buf.withUnsafeMutableBytes { raw -> Int in
                archive_read_data(archive, raw.baseAddress, bufSize)
            }
            if n < 0 {
                lastDataStatus = n
                throw ArchiveAdapterError.archiveUnreadable(url, reason: errorMessage())
            }
            if n == 0 { break }
            if let producedLimit, Int64(out.count) + Int64(n) > producedLimit {
                throw ArchiveAdapterError.archiveUnreadable(url, reason: TarWalkBudget.overrunReason)
            }
            if ArchiveEntrySizeLimit.shouldReject(size: out.count + n, limit: maxEntryBytes) {
                throw ArchiveAdapterError.archiveUnreadable(
                    url,
                    reason: "entry exceeds \(maxEntryBytes) byte cap (decompression-bomb guard)"
                )
            }
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
