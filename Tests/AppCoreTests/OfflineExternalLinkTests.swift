// SPDX-License-Identifier: MIT
import Foundation
import Testing
import LibraryServerAPI
@testable import AppCore

@Suite("G54-S2: 外部ビューアへ渡す題名リンク")
struct OfflineExternalLinkTests {
    private func makeBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g54s2-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `BookDetailDTO` の初期化子は引数が多い。`Tests/AppCoreTests/OfflineStoreTests.swift:9-14` の
    /// 既存ヘルパと**同じ並び**で書くこと（勝手に省略すると通らない）。
    private func detail(_ id: Int, _ title: String) -> BookDetailDTO {
        BookDetailDTO(id: id, title: title, author: nil, genre: nil, path: nil,
            dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 2,
            pages: nil, rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil,
            neta: nil, memo: nil, series: nil, volume: nil, coverImageName: nil,
            coverCropRectJSON: nil, pageDirection: nil)
    }

    private func makeBook(id: Int, title: String, serverID: UUID, libraryUUID: String,
                          ext: String) -> DownloadedBook {
        DownloadedBook(detail: detail(id, title), serverID: serverID, libraryUUID: libraryUUID,
                       libraryName: "L",
                       relativeFilePath: "\(serverID.uuidString)/\(libraryUUID)/\(id).\(ext)",
                       hasCachedCover: false, downloadedAt: Date(), lastPage: nil)
    }

    private func writeBody(_ base: URL, _ book: DownloadedBook) throws -> URL {
        let url = base.appendingPathComponent(book.relativeFilePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("body".utf8).write(to: url)
        return url
    }

    @Test("題名がファイル名になる")
    func titleBecomesFileName() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let book = makeBook(id: 7, title: "吾輩は猫である", serverID: UUID(),
                            libraryUUID: UUID().uuidString, ext: "epub")
        let body = try writeBody(base, book)
        let link = OfflineExternalLink(baseDirectory: base)
        let url = link.linkURL(for: book, fileURL: body)
        #expect(url.lastPathComponent == "吾輩は猫である.epub")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == Data("body".utf8))
    }

    @Test("別のサーバの同じ番号がぶつからない")
    func sameIDDifferentServers() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let lib = UUID().uuidString
        let a = makeBook(id: 5, title: "A", serverID: UUID(), libraryUUID: lib, ext: "zip")
        let b = makeBook(id: 5, title: "B", serverID: UUID(), libraryUUID: lib, ext: "zip")
        let link = OfflineExternalLink(baseDirectory: base)
        let ua = link.linkURL(for: a, fileURL: try writeBody(base, a))
        let ub = link.linkURL(for: b, fileURL: try writeBody(base, b))
        #expect(ua != ub)
        #expect(FileManager.default.fileExists(atPath: ua.path))
        #expect(FileManager.default.fileExists(atPath: ub.path))
    }

    @Test("同じ題名の別の本もぶつからない")
    func sameTitleDifferentBooks() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let sid = UUID(), lib = UUID().uuidString
        let a = makeBook(id: 1, title: "同じ題名", serverID: sid, libraryUUID: lib, ext: "zip")
        let b = makeBook(id: 2, title: "同じ題名", serverID: sid, libraryUUID: lib, ext: "zip")
        let link = OfflineExternalLink(baseDirectory: base)
        let ua = link.linkURL(for: a, fileURL: try writeBody(base, a))
        let ub = link.linkURL(for: b, fileURL: try writeBody(base, b))
        #expect(ua != ub)
        #expect(FileManager.default.fileExists(atPath: ua.path))
        #expect(FileManager.default.fileExists(atPath: ub.path))
    }

    @Test("作り直すと古い名前が残らない")
    func rebuildDropsStaleNames() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let sid = UUID(), lib = UUID().uuidString
        var book = makeBook(id: 3, title: "むかしの題名", serverID: sid, libraryUUID: lib, ext: "zip")
        let body = try writeBody(base, book)
        let link = OfflineExternalLink(baseDirectory: base)
        let old = link.linkURL(for: book, fileURL: body)
        book.detail = detail(3, "あたらしい題名")
        let new = link.linkURL(for: book, fileURL: body)
        #expect(new.lastPathComponent == "あたらしい題名.zip")
        #expect(!FileManager.default.fileExists(atPath: old.path), "古いリンクは消えている")
    }

    @Test("リンクを作れないときは実体をそのまま返す")
    func fallsBackToTheRealFile() throws {
        let base = try makeBase(); defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: base.appendingPathComponent("_external").path)
            try? FileManager.default.removeItem(at: base)
        }
        let book = makeBook(id: 9, title: "T", serverID: UUID(),
                            libraryUUID: UUID().uuidString, ext: "zip")
        let body = try writeBody(base, book)
        let external = base.appendingPathComponent("_external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: external.path)
        let link = OfflineExternalLink(baseDirectory: base)
        #expect(link.linkURL(for: book, fileURL: body) == body)
    }

    @Test("索引に無い本の小部屋だけ消える")
    func pruneKeepsOnlyKnownBooks() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let sid = UUID(), lib = UUID().uuidString
        let keep = makeBook(id: 1, title: "残す", serverID: sid, libraryUUID: lib, ext: "zip")
        let drop = makeBook(id: 2, title: "消す", serverID: sid, libraryUUID: lib, ext: "zip")
        let link = OfflineExternalLink(baseDirectory: base)
        let uk = link.linkURL(for: keep, fileURL: try writeBody(base, keep))
        let ud = link.linkURL(for: drop, fileURL: try writeBody(base, drop))
        link.prune(keeping: [OfflineExternalLink.roomKey(for: keep)])
        #expect(FileManager.default.fileExists(atPath: uk.path))
        #expect(!FileManager.default.fileExists(atPath: ud.path))
    }

    @Test("小部屋を名指しで消せる")
    func removeRoom() throws {
        let base = try makeBase(); defer { try? FileManager.default.removeItem(at: base) }
        let book = makeBook(id: 4, title: "X", serverID: UUID(),
                            libraryUUID: UUID().uuidString, ext: "zip")
        let link = OfflineExternalLink(baseDirectory: base)
        let url = link.linkURL(for: book, fileURL: try writeBody(base, book))
        link.removeRoom(for: book)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("区切り文字とコロンは置換する")
    func replacesSeparators() {
        let n = OfflineExternalLink.safeFileName(title: "a/b:c", fallbackID: 1, fileExtension: "zip")
        #expect(n == "a-b-c.zip")
    }

    @Test("先頭のドットは置換する")
    func replacesLeadingDot() {
        let n = OfflineExternalLink.safeFileName(title: "..hidden", fallbackID: 1, fileExtension: "zip")
        #expect(!n.hasPrefix("."))
        #expect(n.hasSuffix(".zip"))
    }

    @Test("空の題名は ID に落とす")
    func emptyTitleFallsBackToID() {
        #expect(OfflineExternalLink.safeFileName(title: "   ", fallbackID: 42, fileExtension: "zip") == "42.zip")
        #expect(OfflineExternalLink.safeFileName(title: "", fallbackID: 42, fileExtension: "zip") == "42.zip")
    }

    @Test("長すぎる題名は詰める")
    func truncatesLongTitles() {
        let long = String(repeating: "あ", count: 300)   // UTF-8 で 900 バイト
        let n = OfflineExternalLink.safeFileName(title: long, fallbackID: 1, fileExtension: "zip")
        #expect(n.utf8.count <= 204, "題名 200 バイト + \".zip\"")
        #expect(n.hasSuffix(".zip"))
    }
}
