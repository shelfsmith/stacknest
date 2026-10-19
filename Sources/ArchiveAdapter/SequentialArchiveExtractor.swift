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
/// **遠くへ飛んだときは、途中のページを取り出さない**（`pageOrder` を渡したとき）。外部ビューアは保存位置
/// （参照ファイルの開くページ）からいきなり始めるので、先頭から 1 パスで全部を取り出すと、最初の 1 枚が
/// 「途中の全ページの伸長と temp への書き込み」を待つ（200 ページ・182 MB の無圧縮 zip の 190 ページ目で約 260 ms、
/// 先頭のページは約 13 ms。NAS・圧縮した書庫ではさらに延びる）。目的のページの並びで `skipWindow` 枚より手前の
/// ページは読み飛ばして記録だけ残し（`skipped` ＝カーソルより後ろにある取り出していないページ）、後でそのページを
/// 頼まれたら、そのときだけ頭から開き直し、目的のページまで通過するページを全部取り出す。開き直すとカーソルは頭へ
/// 戻るので、読み飛ばしの記録は消える（残りのページはまたカーソルより前にある）。開き直しは「カーソルより後ろの
/// 取り出していないページ」を頼まれたときだけで、開き直した後に前へ順に読むときや、取り出したページへ戻るときには起きない。
/// 読み飛ばすのは、読み飛ばしが位置を移すだけで済む形式（zip と、圧縮していない tar）のときだけ（`skipIsCheap`）。
/// 7z・rar のソリッドや gzip の tar では、読み飛ばしにも伸長が要るので速くならず、戻ったときの開き直しの分だけ遅くなる。
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
    /// ページの並び（`listImageEntries` の順）でのそのページの位置。nil なら読み飛ばさない（従来どおり全部取り出す）。
    private let pageIndex: [String: Int]?
    /// 目的のページより手前で、取り出して残すページの枚数（後ろへめくる・見開きの相方・先読みの分）。
    static let skipWindow = 8
    /// 読み飛ばしたページ（カーソルはもう先にある）。頼まれたら頭から開き直して取り出す。開き直すと消す（`resetHandle`）。
    private var skipped = Set<String>()
    /// この書庫の形式で、読み飛ばしが位置を移すだけで済むか（最初のヘッダを読んだ後に決める。形式は開き直しても変わらない）。
    private var skipIsCheap: Bool?

    /// libarchive ハンドル。アクセスは actor が直列化する（deinit の解放のためだけ
    /// nonisolated(unsafe)＝実アクセスは全て actor 上なので安全）。
    private nonisolated(unsafe) var archive: OpaquePointer?
    private var opened = false
    private var atEOF = false
    /// 抽出済みエントリ名 → temp ファイル URL。
    private var extracted: [String: URL] = [:]

    /// - Parameter pageOrder: ページの並び（`listImageEntries` の順）。渡すと、遠くへ飛んだときに手前のページを
    ///   取り出さない（型コメント）。nil なら従来どおり通過したページを全部取り出す。
    public init(url: URL, imageNames: Set<String>, maxEntryBytes: Int = ArchiveEntrySizeLimit.maxEntryBytes,
                walkLimits: TarWalkLimits = .standard, allowsCompressedTar: Bool = false, pageOrder: [String]? = nil) {
        self.url = url
        self.imageNames = imageNames
        self.pageIndex = pageOrder.map { names in
            var table: [String: Int] = [:]
            table.reserveCapacity(names.count)
            for (index, name) in names.enumerated() where table[name] == nil { table[name] = index }
            return table
        }
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
    /// - **EOF まで未発見**: 外部でファイルが差し替わった等に備え 1 回だけ再オープンして再走査。
    public func data(forName name: String) throws -> Data {
        if let fileURL = extracted[name] {
            return try Data(contentsOf: fileURL)
        }
        // 読み飛ばしたページ: カーソルはもう先にある。頭から開き直し、従来どおり通過するページを全部取り出す
        // （戻る読み方で開き直しを繰り返さない ―― 型コメント）。読み取りエラーの再試行・EOF の再走査は下の通常の道と同じ。
        let wasSkipped = skipped.contains(name)
        if wasSkipped { resetHandle() }
        do {
            if let data = try streamForward(to: name, extractsAll: wasSkipped) { return data }
        } catch is CancellationError {
            throw CancellationError()          // カーソル有効のまま（次要求が続きから進める）
        } catch ArchiveAdapterError.archiveUnreadable(let u, let reason)
                    where reason == TarWalkBudget.exceededReason || reason == TarWalkBudget.overrunReason {
            // G64: 上限超過は何度やっても同じ。ハンドルを捨てて再試行すると上限までの歩きを繰り返すだけなので、そのまま投げる。
            throw ArchiveAdapterError.archiveUnreadable(u, reason: reason)
        } catch {
            resetHandle()                      // 破損等: ハンドルを捨てる
            // 再オープンして 1 回だけ再試行。読み飛ばしは同じ決まりで(遠くのページを頼まれたのなら、やり直しでも手前は取り出さない。
            // 2 回目のレビュー L-1: 以前は全部取り出していた)。
            if let data = try? streamForward(to: name, extractsAll: wasSkipped) { return data }
            throw error
        }
        // EOF まで見つからず: ファイル差し替え等を想定して 1 回だけ再オープン再走査。
        resetHandle()
        if let data = try streamForward(to: name, extractsAll: wasSkipped) { return data }
        throw ArchiveAdapterError.noImageEntry(url)
    }

    /// 試験用: 取り出して temp に置いたページの数と、読み飛ばしたページの数。
    var extractedCountForTesting: Int { extracted.count }
    var skippedCountForTesting: Int { skipped.count }

    // MARK: - private

    /// 現在の cursor から物理順に前方ストリームし、`name` を見つけたらそのデータを返す。
    /// EOF まで見つからなければ nil。読み取りエラーは throw。既抽出エントリは再抽出せずスキップ
    /// （再オープン後の重複抽出＝temp リークを防ぐ）。
    /// `extractsAll` が false なら、目的のページの並びで `skipWindow` 枚より手前のページは取り出さずに読み飛ばす。
    private func streamForward(to name: String, extractsAll: Bool = false) throws -> Data? {
        try openIfNeeded()
        // 読み飛ばしてよいページの位置の上限（これより手前は取り出さない）。並びを知らない・目的が並びに無いなら読み飛ばさない。
        let skipBelow: Int? = extractsAll ? nil : pageIndex?[name].map { $0 - Self.skipWindow }
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
            // 目的のページから遠い手前のページは取り出さない（型コメント）。読み飛ばしが安い形式のときだけ。
            if let skipBelow, entryName != name, let index = pageIndex?[entryName], index < skipBelow,
               let archive, isSkipCheap(archive) {
                archive_read_data_skip(archive)
                skipped.insert(entryName)
                continue
            }
            let data = try readCurrentEntryData(entry: entry)
            let fileURL = tempDir.appendingPathComponent(UUID().uuidString)
            try data.write(to: fileURL, options: .atomic)
            extracted[entryName] = fileURL
            skipped.remove(entryName)
            if entryName == name { return data }
        }
        return nil
    }

    /// 読み飛ばしが位置を移すだけで済む形式か: zip（`archive_read_open_filename` は位置を移せるので、伸長せずに次の
    /// エントリへ移る）と、フィルタの無い tar。ヘッダを読んだ後に呼ぶ（形式とフィルタはそこで決まる）。
    private func isSkipCheap(_ archive: OpaquePointer) -> Bool {
        if let skipIsCheap { return skipIsCheap }
        let format = archive_format(archive) & ARCHIVE_FORMAT_BASE_MASK
        let cheap = (format == ARCHIVE_FORMAT_ZIP || format == ARCHIVE_FORMAT_TAR)
            && archive_filter_code(archive, 0) == ARCHIVE_FILTER_NONE
        skipIsCheap = cheap
        return cheap
    }

    /// libarchive ハンドルを解放し、次回 `openIfNeeded()` で頭から開き直せる状態に戻す。
    /// 抽出済み temp キャッシュ（`extracted`）は保持する（再オープンで再抽出しないため）。
    private func resetHandle() {
        if let archive { archive_read_free(archive) }
        archive = nil
        opened = false
        atEOF = false
        // カーソルが頭へ戻るので、読み飛ばしたページはどれもまたカーソルより前にある（通常の前方ストリームで届く）。
        skipped.removeAll()
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
