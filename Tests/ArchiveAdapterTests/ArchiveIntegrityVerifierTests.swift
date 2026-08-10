// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

/// G27b Task 1: `ArchiveIntegrityVerifier.verify` が実際にエントリのデータを読み、
/// libarchive に CRC を検証させることを確認する。
///
/// **検体はすべて実際に生成する**（モックで済ませない）。zip 組み立ては
/// `DamagedArchiveTests.makeStoredZip`（無圧縮 store・正しい CRC）を再利用する
/// （同一テストターゲット内なので `static func`（デフォルト internal）にアクセス可能）。
struct ArchiveIntegrityVerifierTests {

    /// `makeStoredZip` が生成した無圧縮 zip の、指定エントリの **データ本体** を数バイト反転する。
    /// ローカルヘッダ（署名・CRC フィールド）は無傷のまま残すので、ヘッダ走査だけの実装
    /// （`enumerateImageEntries` 等）は「正常」と誤判定する ―― CRC 検証だけが検出できる。
    ///
    /// 実装: store 方式は「ローカルヘッダの直後に生データがそのまま続く」ので、対象エントリの
    /// 名前を検索してその直後のバイト列を書き換えればよい。
    static func flipEntryData(_ zip: Data, entryName: String, entryData: Data) -> Data {
        var out = zip
        let nameBytes = Array(entryName.utf8)
        var i = 0
        while i + nameBytes.count <= out.count {
            if Array(out[i..<(i + nameBytes.count)]) == nameBytes {
                // ローカルヘッダの name の直後にデータ本体が続く（store・extra なし）。
                // ただし central directory 側にも同じ名前が現れるので、直後が
                // entryData 本体と一致する箇所（= ローカルヘッダの方）だけを書き換える。
                let dataStart = i + nameBytes.count
                if dataStart + entryData.count <= out.count,
                   Array(out[dataStart..<(dataStart + entryData.count)]) == Array(entryData) {
                    // 先頭数バイトを反転（CRC は元のまま = 不一致になる）。
                    let flipCount = min(4, entryData.count)
                    for k in 0..<flipCount {
                        out[dataStart + k] = out[dataStart + k] ^ 0xFF
                    }
                    return out
                }
            }
            i += 1
        }
        return out
    }

    static func writeTemp(_ data: Data, ext: String = "zip") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g27b-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        return url
    }

    // MARK: - 1. 正常な zip

    @Test
    func cleanArchiveHasNoBadEntriesAndCountsImages() async throws {
        let entries = (1...5).map { ("\($0).png", DamagedArchiveTests.tinyPNG) }
        let zip = DamagedArchiveTests.makeStoredZip(entries)
        let url = try Self.writeTemp(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: { false })

        #expect(result.badEntries.isEmpty)
        #expect(result.imageCount == 5)
        #expect(result.entryCount == 5)
        #expect(result.truncated == false)
    }

    // MARK: - 2. CRC を壊した zip

    @Test
    func crcMismatchIsDetectedEvenThoughHeaderIsIntact() async throws {
        let entries = [("1.png", DamagedArchiveTests.tinyPNG),
                        ("2.png", DamagedArchiveTests.tinyPNG),
                        ("3.png", DamagedArchiveTests.tinyPNG)]
        var zip = DamagedArchiveTests.makeStoredZip(entries)
        zip = Self.flipEntryData(zip, entryName: "2.png", entryData: DamagedArchiveTests.tinyPNG)
        let url = try Self.writeTemp(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        // 前提確認: ヘッダ走査だけの既存実装（LibarchiveCoverExtractor）は
        // この壊し方を「正常」と判定する（3 件とも読める）。CRC 検証だけが検出できることの裏付け。
        let headerOnlyListing = try await LibarchiveCoverExtractor().listImageEntries(in: url)
        #expect(headerOnlyListing.names.count == 3)
        #expect(headerOnlyListing.truncated == false)

        let result = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: { false })

        #expect(result.badEntries == ["2.png"])
        #expect(result.entryCount == 3)
        #expect(result.truncated == false)
    }

    // MARK: - 3. 途中で切り詰めた zip

    @Test
    func damagedArchiveReturnsTruncatedWithWhatItCouldVerify() async throws {
        let zip = DamagedArchiveTests.makeDamagedZip()
        let url = try Self.writeTemp(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: { false })

        #expect(result.truncated == true)
        #expect(result.entryCount > 0)
        #expect(result.entryCount < 6)
    }

    @Test
    func archiveDamagedBeforeAnyEntryThrows() async throws {
        let zip = DamagedArchiveTests.makeZipDamagedAtFirstEntry()
        let url = try Self.writeTemp(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            _ = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: { false })
        }
    }

    // MARK: - 4. アーカイブでないファイル

    @Test
    func nonArchiveFileThrows() async throws {
        let url = try Self.writeTemp(Data(repeating: 0x41, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            _ = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: { false })
        }
    }

    // MARK: - 5. 絶対パスが結果に含まれない

    @Test
    func resultNeverContainsAbsolutePathOrFileURL() async throws {
        let entries = [("1.png", DamagedArchiveTests.tinyPNG),
                        ("2.png", DamagedArchiveTests.tinyPNG)]
        var zip = DamagedArchiveTests.makeStoredZip(entries)
        zip = Self.flipEntryData(zip, entryName: "1.png", entryData: DamagedArchiveTests.tinyPNG)
        let url = try Self.writeTemp(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: { false })

        let dump = String(describing: result)
        #expect(!dump.contains("file://"))
        for entry in result.badEntries {
            #expect(!entry.hasPrefix("/"))
        }
        #expect(!dump.contains(url.path))
    }

    // MARK: - 6. 中断

    @Test
    func cancellationStopsPartwayAndReportsTruncated() async throws {
        let entries = (1...20).map { ("\($0).png", DamagedArchiveTests.tinyPNG) }
        let zip = DamagedArchiveTests.makeStoredZip(entries)
        let url = try Self.writeTemp(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        var calls = 0
        let result = try ArchiveIntegrityVerifier.verifySync(url: url, isCancelled: {
            calls += 1
            return calls > 3   // 数エントリ処理させてから中断
        })

        #expect(result.truncated == true)
        #expect(result.entryCount < 20)
        #expect(result.entryCount > 0)
    }
}
