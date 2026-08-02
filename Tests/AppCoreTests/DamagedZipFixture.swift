// SPDX-License-Identifier: MIT
import Foundation

/// `Tests/ArchiveAdapterTests/DamagedArchiveTests.swift` の `makeStoredZip` /
/// `crc32` / `tinyPNG` / 署名破壊ロジックの**意図的な複製**。
///
/// `Tests/ArchiveAdapterTests` と `Tests/AppCoreTests` は `Package.swift` 上の別テスト
/// ターゲット（それぞれ `path:` で自ディレクトリのみを見る）で、共有するには
/// `Tests/TestSupport/` 相当の新規ターゲットが要る。テストヘルパ 40 行のために本番の
/// 依存グラフへターゲットを 1 つ増やすのは割に合わないので、新規ターゲットは作らず
/// 複製する。**片方を直したらもう片方も直すこと。**
enum DamagedZipFixture {
    /// 無圧縮(store)の最小 zip を組み立てる。entries は (名前, 中身) の配列。
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

    /// 3 件目のローカルヘッダ署名を壊した zip。libarchive はそこで ARCHIVE_FATAL を返す
    /// （`DamagedArchiveTests.makeDamagedZip()` と同じ構造）。
    static func makeDamagedZip() -> Data {
        var zip = makeStoredZip((1...6).map { ("\($0).png", tinyPNG) })
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

    /// 破損 zip を一時ファイルへ書き出す。呼び出し側で `removeItem` すること。
    static func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g26-appcore-\(UUID().uuidString).zip")
        try makeDamagedZip().write(to: url)
        return url
    }
}
