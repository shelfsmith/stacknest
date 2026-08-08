// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

/// G27b fixup: RAR のディレクトリエントリは ZIP と違って名前に末尾 "/" を付けない
/// （`rar` CLI で実際に作った RAR5 を `unrar lb` で確認済み: "somedir" であって "somedir/" ではない）。
/// `ArchiveIntegrityVerifier.verify` がこれを名前規約だけでディレクトリ判定していたため、
/// RAR のディレクトリエントリがデータ読み取りループに入り `archive_read_data` が負値
/// （実測 -30, "Can't decompress an entry marked as a directory"）を返し、健全な RAR 本を
/// 「破損」と誤判定していた（実機 smoke で発覚）。
///
/// **検体は実際に `rar` CLI（本機に導入済み: `command -v rar`）で生成する**。ZIP 用の
/// バイト組み立てヘルパー (`DamagedArchiveTests.makeStoredZip`) では RAR の挙動を
/// 再現できない（これはコードから推測できる話ではなく、libarchive の RAR リーダーの
/// 実装依存の挙動 —— 事実、controller は C ハーネスで実測してから本 fix を指示した）。
/// `rar` が見つからない場合はテストを **fail** させる（黙ってスキップしない）。
struct ArchiveIntegrityVerifierRARDirectoryTests {

    enum FixtureError: Error {
        case rarExecutableNotFound
        case rarCommandFailed(Int32)
    }

    // MARK: - rar CLI 実行ヘルパー

    /// `rar` 実行ファイルを探す。見つからなければ nil。
    ///
    /// **`rar` は proprietary で、GitHub Actions のランナーには入っていない**（2026-08-08 の
    /// CI 有効化で判明）。ライセンス上 CI へ導入するのも望ましくないため、
    /// 無い環境では**理由付きでスキップ**する（`@Test(.enabled(if:))`）。
    /// 黙って通すのでも落とすのでもなく、「検証していない」と報告させるのが目的。
    ///
    /// **副作用として CI では RAR 経路が一切検証されない。** RAR のディレクトリ誤判定は
    /// 実機 smoke で見つかった実バグ（G27b）なので、検体をリポジトリに置いて
    /// `rar` 非依存にする案を follow-up として起票してある。
    static func rarExecutableIfAvailable() -> String? {
        let candidates = ["/usr/local/bin/rar", "/opt/homebrew/bin/rar"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/rar"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// `rar` が使えることを前提とする箇所用。無ければ throw する（呼び出し側は
    /// `.enabled(if:)` で既に弾かれているはずなので、ここに来るのは想定外）。
    static func resolveRarExecutable() throws -> String {
        let candidates = ["/usr/local/bin/rar", "/opt/homebrew/bin/rar"]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = "\(dir)/rar"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        throw FixtureError.rarExecutableNotFound
    }

    @discardableResult
    static func runRar(_ executable: String, arguments: [String], currentDirectory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - 検体 1: ディレクトリを含む健全な RAR

    /// ディレクトリ 1 件（末尾 "/" なし） + 通常ファイル 2 件を含む RAR5 アーカイブを実際に作る。
    static func makeRealRARWithDirectory() throws -> URL {
        let rarExe = try resolveRarExecutable()
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g27b-rardir-\(UUID().uuidString)")
        let srcDir = workDir.appendingPathComponent("src")
        let subDir = srcDir.appendingPathComponent("somedir")
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try Data("hello world content for file one\n".utf8).write(to: srcDir.appendingPathComponent("file1.txt"))
        try Data("hello world content in dir\n".utf8).write(to: subDir.appendingPathComponent("file2.txt"))

        let rarURL = workDir.appendingPathComponent("test.rar")
        // -r: 再帰的にディレクトリを含める（これが空でないディレクトリでも rar 自身のエントリとして
        //     "somedir" を作る所以）。-ma5: RAR5 形式。-idq: バナー等の出力を抑制。
        let status = try runRar(rarExe,
                                 arguments: ["a", "-r", "-ma5", "-idq", rarURL.path, "."],
                                 currentDirectory: srcDir)
        guard status == 0 else { throw FixtureError.rarCommandFailed(status) }
        return rarURL
    }

    // MARK: - 検体 2: 圧縮エントリが実際に壊れている RAR

    /// ランダムな大きめテキスト 1 件を **圧縮ありで** RAR に固め、生成後にファイル内容の
    /// 中間バイトを反転して壊す。ヘッダの CRC はそのままなので、圧縮ストリーム側の破損だけが
    /// 残る —— controller の実測どおり `archive_read_data` が負値（実測 -25, 解凍エラー）を返す。
    /// これにより「fix が RAR の全エラーを握り潰していないか」を確認する。
    static func makeRealRARWithCorruptedCompressedEntry() throws -> URL {
        let rarExe = try resolveRarExecutable()
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g27b-rarcorrupt-\(UUID().uuidString)")
        let srcDir = workDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        // 圧縮が効くように十分な長さ・低エントロピーのランダム文字列を作る（store 化を避ける）。
        let alphabet = Array("ABCDEFGHIJ")
        var generator = SystemRandomNumberGenerator()
        let content = String((0..<20000).map { _ in alphabet.randomElement(using: &generator)! })
        let fileURL = srcDir.appendingPathComponent("big.txt")
        try Data(content.utf8).write(to: fileURL)

        let rarURL = workDir.appendingPathComponent("corrupt.rar")
        let status = try runRar(rarExe,
                                 arguments: ["a", "-m5", "-ma5", "-idq", rarURL.path, "big.txt"],
                                 currentDirectory: srcDir)
        guard status == 0 else { throw FixtureError.rarCommandFailed(status) }

        var raw = try Data(contentsOf: rarURL)
        #expect(raw.count > 200, "compressed archive should be reasonably sized for a safe mid-file flip")
        // 先頭のヘッダ領域(たかだか数百バイト)を避け、圧縮データ本体の中間を反転する。
        let flipStart = raw.count / 2
        for offset in 0..<8 {
            raw[flipStart + offset] ^= 0xFF
        }
        try raw.write(to: rarURL)
        return rarURL
    }

    // MARK: - テスト本体

    /// 本 fix のリグレッションテスト: RAR のディレクトリ（末尾 "/" なし）が
    /// `entryCount`/`badEntries` に混入せず、本全体が健全と判定されることを確認する。
    @Test(.enabled(if: ArchiveIntegrityVerifierRARDirectoryTests.rarExecutableIfAvailable() != nil,
                   "rar 実行ファイルが無いためスキップ（proprietary のため CI には導入しない）"))
    func rarDirectoryEntryWithoutTrailingSlashIsNotFlaggedAsDamaged() async throws {
        let url = try Self.makeRealRARWithDirectory()
        // workDir (= url の親。src/ と test.rar をまとめて持つ) ごと片付ける。
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await ArchiveIntegrityVerifier.verify(url: url, isCancelled: { false })

        #expect(result.badEntries.isEmpty)
        #expect(result.truncated == false)
        // ディレクトリ自身(somedir)はエントリ数に含めない。file1.txt / somedir/file2.txt の 2 件だけ。
        #expect(result.entryCount == 2)
        #expect(!result.badEntries.contains("somedir"))
    }

    /// fix が RAR の全エラーを握り潰していないことの確認: 圧縮ストリームが実際に
    /// 壊れているエントリは引き続き badEntries に検出される。
    @Test(.enabled(if: ArchiveIntegrityVerifierRARDirectoryTests.rarExecutableIfAvailable() != nil,
                   "rar 実行ファイルが無いためスキップ（proprietary のため CI には導入しない）"))
    func genuinelyCorruptedRAREntryIsStillDetected() async throws {
        let url = try Self.makeRealRARWithCorruptedCompressedEntry()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let result = try await ArchiveIntegrityVerifier.verify(url: url, isCancelled: { false })

        #expect(result.badEntries == ["big.txt"])
        #expect(result.truncated == false)
        #expect(result.entryCount == 1)
    }
}
