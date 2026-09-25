// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI
@testable import LibraryServer

/// G54-S3e（spec §2.4）: DTO が実際に出す JSON のキーが、openapi.yaml のそのスキーマの properties に全部あること。
/// S3d で Web が `filename` を使い始めたのに spec に無かった（食い違いが黙って育った）のを繰り返さない。
/// YAML のパーサは依存に無いので、`components.schemas.<名前>.properties` 直下（字下げ 8）のキーだけを拾う。
@Suite("G54-S3e: openapi.yaml と DTO の食い違い")
struct OpenAPIDTOParityTests {
    private func specText() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LibraryServerTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // リポジトリ直下
            .appendingPathComponent("Sources/LibraryServer/Resources/openapi/openapi.yaml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// `components.schemas.<schema>.properties` のキー（字下げ 8 の行）。スキーマが無ければ空。
    static func propertyNames(of schema: String, in yaml: String) -> Set<String> {
        var names: Set<String> = []
        var inSchema = false
        var inProperties = false
        for raw in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if !inSchema {
                if line == "    \(schema):" { inSchema = true }
                continue
            }
            if indent <= 4 { break }                                   // 次のスキーマ
            if indent == 6 { inProperties = (trimmed == "properties:"); continue }
            if inProperties, indent == 8, let colon = trimmed.firstIndex(of: ":") {
                names.insert(String(trimmed[..<colon]))
            }
        }
        return names
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: e.encode(value)) as? [String: Any] ?? [:]
    }

    /// 省略できるフィールドを全部埋めた一覧の 1 件（nil のキーは JSON に出ないので、全部埋めないと検出できない）。
    private func fullListItem() -> BookListItemDTO {
        BookListItemDTO(
            id: 1, title: "t", author: "a", series: "s", volume: 1, rating: 3, unseen: true, bookType: 0,
            pages: 10, lastPage: 2, lastReadAt: Date(timeIntervalSince1970: 0), dateAdded: Date(timeIntervalSince1970: 0),
            hasCover: true, coverVersion: "v", genre: "g", neta: "n", keywordA: "ka", keywordB: "kb", keywordC: "kc",
            memo: "m", coverCropRectJSON: "{}", filename: "a.zip")
    }

    private func fullDetail() -> BookDetailDTO {
        BookDetailDTO(
            id: 1, title: "t", author: "a", genre: "g", path: "p",
            dateAdded: Date(timeIntervalSince1970: 0), playDate: Date(timeIntervalSince1970: 0),
            bookType: 0, fileType: 0, pages: 10, lastPage: 2,
            epubLocator: EPUBLocatorDTO(spine: 1, progress: 0.5, cfi: "c", engine: "washi"),
            rating: 3, unseen: true, keywordA: "ka", keywordB: "kb", keywordC: "kc",
            neta: "n", memo: "m", series: "s", volume: 1,
            coverImageName: "c.jpg", coverCropRectJSON: "{}", pageDirection: "rtl",
            fileExtension: "zip", filename: "a.zip", previous: BookPatchDTO(title: "old"))
    }

    private func expectKeys(_ keys: some Sequence<String>, in schema: String, spec: String) {
        let names = Self.propertyNames(of: schema, in: spec)
        #expect(!names.isEmpty, "openapi.yaml に \(schema) が見つからない（読み方が壊れている）")
        let missing = Set(keys).subtracting(names)
        #expect(missing.isEmpty, "openapi.yaml の \(schema) に無いキー: \(missing.sorted())")
    }

    @Test func bookListItemKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(fullListItem()).keys, in: "BookListItemDTO", spec: spec)
    }

    @Test func bookDetailKeysAreInTheSpec() throws {
        let spec = try specText()
        expectKeys(try object(fullDetail()).keys, in: "BookDetailDTO", spec: spec)
    }

    @Test func bookPageKeysAreInTheSpec() throws {
        let spec = try specText()
        let page = try object(BookPageDTO(items: [fullListItem()], total: 1, page: 1, perPage: 50))
        expectKeys(page.keys, in: "BookPageDTO", spec: spec)
        let item = (page["items"] as? [[String: Any]])?.first ?? [:]
        expectKeys(item.keys, in: "BookListItemDTO", spec: spec)
    }

    @Test func adjacentVolumeKeysAreInTheSpec() throws {
        let spec = try specText()
        let reply = try object(AdjacentVolumeReply(book: fullListItem()))
        expectKeys(reply.keys, in: "AdjacentVolumeReply", spec: spec)
        expectKeys((reply["book"] as? [String: Any] ?? [:]).keys, in: "BookListItemDTO", spec: spec)
    }

    /// 読み方そのものの確かめ（入れ子の properties・次のスキーマのキーを拾わない）。
    @Test func readerPicksOnlyTheSchemaOwnProperties() {
        let yaml = """
        components:
          schemas:
            A:
              type: object
              properties:
                x:
                  type: object
                  properties:
                    nested: { type: integer }
                y: { type: string }
              required: [x]
            B:
              properties:
                z: { type: integer }
        """
        #expect(Self.propertyNames(of: "A", in: yaml) == ["x", "y"])
        #expect(Self.propertyNames(of: "B", in: yaml) == ["z"])
        #expect(Self.propertyNames(of: "C", in: yaml).isEmpty)
    }
}
