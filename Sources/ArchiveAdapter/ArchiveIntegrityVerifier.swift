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

    /// libarchive にファイルから読ませる 1 回分のサイズ（G34a fix2）。
    /// `F_NOCACHE` で先読みが無くなるため、既定の 16KB では小さすぎる（上記 `verifySync` 参照）。
    private static let readBlockSize = 1 << 20

    /// `archive_entry.h` の `AE_IFDIR`（= POSIX `S_IFDIR`, 0o040000）と同じ値。
    /// マクロは `((__LA_MODE_T)0040000)` という入れ子キャスト式で定義されており、
    /// Clang importer がこの形を Swift 定数として取り込めない（実測: `AE_IFDIR` は
    /// `import Carchive` 後も "cannot find in scope"）。`archive_entry_filetype` の
    /// 戻り値型 `mode_t` に対して同じ値をここで再定義して比較する。
    private static let entryFileTypeDirectory: mode_t = 0o040000

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
    ///
    /// **★ `Sync` の意味（G34a）: この関数はブロックする。協調スレッドプール上で呼んではいけない。**
    /// 実測（`sample`・2026-08-10）で、この関数は時間の 70% を `read()` syscall に費やす
    /// 完全な I/O 律速であり、1 冊あたり数秒間スレッドを占有し続ける。走査は
    /// `ThrottledIOExecutor` の専用スレッド（低 QoS ＋ `IOPOL_THROTTLE`）から呼ぶこと。
    ///
    /// 同期であること自体が要件でもある。`setiopolicy_np` は**スレッド単位**の設定なので、
    /// 協調プールのスレッドに設定するとそのスレッドが後で拾う無関係なタスクにまで
    /// スロットルが漏れる。専用スレッド上で**中断しない同期ループ**として走ることが前提。
    ///
    /// G34a 以前は `isCancelled: () async -> Bool` を取る async 版だったが、
    /// 上記の理由で同期版へ一本化した（本番呼び出しは `FullIntegrityScanner.liveDependencies`
    /// の 1 箇所のみで、そこは実行器経由になったため async 版に利用者がいなくなった）。
    public static func verifySync(url: URL, isCancelled: () -> Bool = { false }) throws -> ArchiveVerifyResult {
        // ★ G34a fix2: ファイルは**自分で開いて `F_NOCACHE` を立ててから**渡す。
        //
        // 走査は 1 冊あたり数十 MB を読んで**すべて捨てる**（CRC を検証したいだけでデータは要らない）。
        // 既定の経路（`archive_read_open_filename`）ではその全バイトがユニファイドバッファ
        // キャッシュを通るため、ユーザーが見ているサムネイル・DB ページが片端から追い出される。
        //
        // 実測（2026-08-11・32GB 機）: 走査中は `Pages free` が 15MB まで落ち、
        // **たった今読んだサムネイルを読み直しても p50 71.8ms**（走査していなければ 0.08ms）。
        // その差は約 900 倍で、これが「走査中にアプリだけもっさりする」の主因だった。
        // `IOPOL_THROTTLE`（デバイスの順番待ちを後回しにする）はこの問題には**無力**である
        // ―― 順番の話であってキャッシュの話ではないため。両方要る。
        //
        // `F_NOCACHE` は「このディスクリプタの読み書きをキャッシュに残さない」指示なので、
        // 読み捨てるだけの走査には理想的（走査自身は 1 度しか読まないので損もしない）。
        //
        // ★ fd は `archive` より**先に**開く。Swift の `defer` は LIFO なので、
        // 先に宣言した `close(fd)` が最後に走り、`archive_read_free` の後始末が
        // 閉じた fd に触るのを避けられる（`archive_read_open_fd` は fd の所有権を取らない）。
        guard let fd = Self.openForStreamingWithoutCaching(url) else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "open failed")
        }
        defer { close(fd) }

        guard let archive = archive_read_new() else {
            throw ArchiveAdapterError.archiveUnreadable(url, reason: "archive_read_new failed")
        }
        defer { archive_read_free(archive) }

        archive_read_support_format_zip(archive)
        archive_read_support_format_rar(archive)
        archive_read_support_format_rar5(archive)
        archive_read_support_format_7zip(archive)
        archive_read_support_filter_all(archive)

        // ブロックサイズは 16KB ではなく 1MB。`F_NOCACHE` はカーネルの先読みも止めるため、
        // 16KB のままだと 50MB の本で 3,200 回の小さなデバイス read になり、走査が 16% 遅くなった
        // （実測 1.41 → 1.63 秒/冊）。libarchive に大きく読ませて取り返す。
        let status = archive_read_open_fd(archive, fd, Self.readBlockSize)
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
            if isCancelled() {
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
            // ディレクトリ判定は entry の filetype を正とする（ZIP は名前に "/" を付けるが、
            // RAR はディレクトリでも末尾 "/" を付けない実測がある。名前規約だけに頼ると
            // RAR のディレクトリエントリが「データを読むべきエントリ」としてすり抜け、
            // archive_read_data が負値を返して誤って badEntries=破損扱いになる）。
            // hasSuffix は filetype が未確定な場合の保険として残す。
            let isDirectory = archive_entry_filetype(entry) == Self.entryFileTypeDirectory || name.hasSuffix("/")
            if isDirectory {
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

    /// `<sys/fcntl.h>` の `F_NOCACHE`。「このディスクリプタの I/O をバッファキャッシュに残さない」。
    /// Swift からは定数として見えないため値を再定義する（`AE_IFDIR` と同じ事情）。
    private static let fNoCache: Int32 = 48

    /// 読み捨て前提のストリーミング用にファイルを開く。**開けたら必ず `F_NOCACHE` を試みる。**
    ///
    /// `F_NOCACHE` に失敗しても読み取り自体は続行する（キャッシュ汚染は起きるが、
    /// 検査ができなくなるよりはよい）。失敗を握り潰さずログに残すのは、
    /// 「効いているつもり」で走らせないため ―― 効いたかどうかは `fcntl(F_NOCACHE)` の
    /// 戻り値でしか分からず、外から観測する手段がないので、ここで記録するしかない。
    static func openForStreamingWithoutCaching(_ url: URL) -> Int32? {
        let fd = url.path.withCString { open($0, O_RDONLY) }
        guard fd >= 0 else { return nil }
        if fcntl(fd, fNoCache, 1) == -1 {
            logger.error("F_NOCACHE not applied (errno=\(errno, privacy: .public)) — scan will evict the UI's cached pages")
        }
        return fd
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
