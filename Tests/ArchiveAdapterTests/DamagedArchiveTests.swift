// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import ArchiveAdapter

/// 破損アーカイブでも「読めた分」を返すことを検証する。
///
/// **なぜ合成するのか**: 破損の実例はユーザーの蔵書であり repo に入れられない
/// （`docs/02_constraints.md`）。zip をその場で組み立て、途中のローカルヘッダ署名を
/// 壊すことで libarchive に `ARCHIVE_FATAL`（"Damaged Zip archive"）を返させる。
struct DamagedArchiveTests {

    /// 無圧縮(store)の最小 zip を組み立てる。entries は (名前, 中身) の配列。
    /// 破損させやすいよう store 固定・CRC は正しく計算する。
    static func makeStoredZip(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        var offsets: [Int] = []

        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        for (name, body) in entries {
            offsets.append(out.count)
            let nameBytes = Data(name.utf8)
            let crc = crc32(body)
            // local file header
            out.append(u32(0x0403_4b50))          // signature
            out.append(u16(10))                   // version needed
            out.append(u16(0x0800))               // flags: UTF-8 名前
            out.append(u16(0))                    // method: store
            out.append(u16(0)); out.append(u16(0))// time, date
            out.append(u32(crc))
            out.append(u32(UInt32(body.count)))   // compressed
            out.append(u32(UInt32(body.count)))   // uncompressed
            out.append(u16(UInt16(nameBytes.count)))
            out.append(u16(0))                    // extra len
            out.append(nameBytes)
            out.append(body)
        }
        for (i, (name, body)) in entries.enumerated() {
            let nameBytes = Data(name.utf8)
            central.append(u32(0x0201_4b50))
            central.append(u16(20)); central.append(u16(10))
            central.append(u16(0x0800)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(crc32(body)))
            central.append(u32(UInt32(body.count)))
            central.append(u32(UInt32(body.count)))
            central.append(u16(UInt16(nameBytes.count)))
            central.append(u16(0)); central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(0))
            central.append(u32(UInt32(offsets[i])))
            central.append(nameBytes)
        }
        let centralOffset = out.count
        out.append(central)
        out.append(u32(0x0605_4b50))              // EOCD
        out.append(u16(0)); out.append(u16(0))
        out.append(u16(UInt16(entries.count)))
        out.append(u16(UInt16(entries.count)))
        out.append(u32(UInt32(central.count)))
        out.append(u32(UInt32(centralOffset)))
        out.append(u16(0))
        return out
    }

    /// zlib 非依存の CRC-32（テスト用の素朴実装）。
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// 1x1 の最小 PNG（画像拡張子として認識させるためだけのダミー）。
    static let tinyPNG = Data([
        0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A, 0x00,0x00,0x00,0x0D,
        0x49,0x48,0x44,0x52, 0x00,0x00,0x00,0x01, 0x00,0x00,0x00,0x01,
        0x08,0x06,0x00,0x00,0x00, 0x1F,0x15,0xC4,0x89,
        0x00,0x00,0x00,0x0A, 0x49,0x44,0x41,0x54,
        0x78,0x9C,0x63,0x00,0x01,0x00,0x00,0x05,0x00,0x01,
        0x0D,0x0A,0x2D,0xB4, 0x00,0x00,0x00,0x00, 0x49,0x45,0x4E,0x44,
        0xAE,0x42,0x60,0x82
    ])

    static func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g26-\(UUID().uuidString).zip")
        try data.write(to: url)
        return url
    }
}

extension DamagedArchiveTests {
    @Test func intactArchiveListsEveryEntry() async throws {
        let zip = Self.makeStoredZip((1...5).map { ("\($0).png", Self.tinyPNG) })
        let url = try Self.writeTemp(zip)
        defer { try? FileManager.default.removeItem(at: url) }

        let listing = try await LibarchiveCoverExtractor().listImageEntries(in: url)
        #expect(listing.names.count == 5)
        #expect(listing.truncated == false)
    }
}

extension DamagedArchiveTests {
    /// 3 件目のローカルヘッダ署名を壊した zip。libarchive はそこで ARCHIVE_FATAL を返す。
    static func makeDamagedZip() -> Data {
        var zip = makeStoredZip((1...6).map { ("\($0).png", tinyPNG) })
        // 3 件目のローカルヘッダ署名 (0x04034b50) を探して壊す。
        let sig: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        var found = 0
        var i = 0
        while i + 4 <= zip.count {
            if Array(zip[i..<i+4]) == sig {
                found += 1
                if found == 3 { zip[i + 2] = 0xFF; break }   // 署名を破壊
            }
            i += 1
        }
        return zip
    }

    @Test func damagedArchiveReturnsWhatItCouldRead() async throws {
        let url = try Self.writeTemp(Self.makeDamagedZip())
        defer { try? FileManager.default.removeItem(at: url) }

        let listing = try await LibarchiveCoverExtractor().listImageEntries(in: url)
        // 壊した位置より前のエントリは読めているはず（全 6 件より少ない）。
        #expect(listing.names.isEmpty == false)
        #expect(listing.names.count < 6)
        #expect(listing.truncated == true)
    }

    /// zip ですらないバイト列 → `archive_read_open_filename` 自体が失敗する経路。
    /// これは G26 より前から存在する分岐で、`names.isEmpty` ガード（下の
    /// `archiveDamagedBeforeAnyEntryThrows`）とは別物。open が失敗するので
    /// 1 回も `archive_read_next_header` に到達しないままエラーになる。
    @Test func openFailureOnNonZipBytesStillThrows() async throws {
        let url = try Self.writeTemp(Data(repeating: 0x41, count: 4096))
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            _ = try await LibarchiveCoverExtractor().listImageEntries(in: url)
        }
    }

    /// 1 件目のローカルヘッダ署名を壊した zip。EOCD・central directory は無傷なので
    /// `archive_read_open_filename` 自体は成功し、**最初の** `archive_read_next_header` が
    /// いきなり `ARCHIVE_FATAL` を返す — つまり `names` が 1 件も集まらないまま致命的
    /// エラーに達する。これで `enumerateImageEntries` の `names.isEmpty` ガード
    /// （壊れたファイルを 0 ページの本として黙って開かせないための分岐）を直接踏む。
    static func makeZipDamagedAtFirstEntry() -> Data {
        var zip = makeStoredZip((1...6).map { ("\($0).png", tinyPNG) })
        let sig: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        var found = 0
        var i = 0
        while i + 4 <= zip.count {
            if Array(zip[i..<i+4]) == sig {
                found += 1
                if found == 1 { zip[i + 2] = 0xFF; break }   // 署名を破壊
            }
            i += 1
        }
        return zip
    }

    @Test func archiveDamagedBeforeAnyEntryThrows() async throws {
        let url = try Self.writeTemp(Self.makeZipDamagedAtFirstEntry())
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: (any Error).self) {
            _ = try await LibarchiveCoverExtractor().listImageEntries(in: url)
        }
    }
}
