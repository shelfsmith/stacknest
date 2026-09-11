// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryServerAPI

/// G51 offline-extension-migration: `OfflineStore.migrateFileExtensions()` が、過去に magic 推定で
/// 誤った拡張子のまま保存された DL 済みファイルを、起動時に本来の拡張子へ安全にリネームすることを
/// 確認する。テストデータは架空の値のみ（実ライブラリには触れない）。
@Suite("OfflineStore.migrateFileExtensions — rename already-downloaded files")
struct OfflineStoreMigrateFileExtensionsTests {
    private let libraryUUID = "11111111-1111-1111-1111-111111111111"
    private let zipMagic = Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])

    private func makeStore() -> (store: OfflineStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("offline-migrate-test-\(UUID().uuidString)", isDirectory: true)
        return (OfflineStore(baseDirectory: dir), dir)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func detail(id: Int, fileExtension: String?) -> BookDetailDTO {
        BookDetailDTO(id: id, title: "T\(id)", author: nil, genre: nil, path: nil,
            dateAdded: Date(timeIntervalSince1970: 0), playDate: nil, bookType: 0, fileType: 2, pages: nil,
            rating: 0, unseen: true, keywordA: nil, keywordB: nil, keywordC: nil, neta: nil, memo: nil,
            series: nil, volume: nil, coverImageName: nil, coverCropRectJSON: nil, pageDirection: nil,
            fileExtension: fileExtension)
    }

    @Test func renamesToServerProvidedExtension() throws {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        // 保存当時は magic 推定で .zip として保存されたが、今はサーバが detail.fileExtension="epub" を返す想定。
        try store.save(detail(id: 1, fileExtension: "epub"), serverID: UUID(), libraryUUID: libraryUUID,
                       libraryName: "Lib", fileExtension: "zip", fileData: zipMagic, coverData: nil)

        let renamed = store.migrateFileExtensions()
        #expect(renamed == 1)

        let reloaded = store.all()
        #expect(reloaded.count == 1)
        let book = try #require(reloaded.first)
        #expect(book.relativeFilePath.hasSuffix(".epub"))
        #expect(!book.relativeFilePath.hasSuffix(".zip"))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: book).path))
    }

    @Test func alreadyMatchingExtensionIsLeftAlone() throws {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        try store.save(detail(id: 2, fileExtension: "epub"), serverID: UUID(), libraryUUID: libraryUUID,
                       libraryName: "Lib", fileExtension: "epub", fileData: zipMagic, coverData: nil)
        let before = try #require(store.all().first)

        let renamed = store.migrateFileExtensions()
        #expect(renamed == 0)

        let after = try #require(store.all().first)
        #expect(after.relativeFilePath == before.relativeFilePath)
    }

    @Test func missingFileIsSkippedWithoutDroppingEntry() throws {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        try store.save(detail(id: 3, fileExtension: "epub"), serverID: UUID(), libraryUUID: libraryUUID,
                       libraryName: "Lib", fileExtension: "zip", fileData: zipMagic, coverData: nil)
        let before = try #require(store.all().first)
        try FileManager.default.removeItem(at: store.fileURL(for: before))

        let renamed = store.migrateFileExtensions()
        #expect(renamed == 0)

        let after = store.all()
        #expect(after.count == 1)
        #expect(after.first?.relativeFilePath == before.relativeFilePath)
    }

    @Test func existingDestinationLeavesEntryUntouched() throws {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        try store.save(detail(id: 4, fileExtension: "epub"), serverID: UUID(), libraryUUID: libraryUUID,
                       libraryName: "Lib", fileExtension: "zip", fileData: zipMagic, coverData: nil)
        let before = try #require(store.all().first)
        // リネーム先に既に別ファイルが存在するケースを作る。
        let conflictingURL = store.fileURL(for: before).deletingPathExtension().appendingPathExtension("epub")
        FileManager.default.createFile(atPath: conflictingURL.path, contents: Data([0x00]))

        let renamed = store.migrateFileExtensions()
        #expect(renamed == 0)

        let after = try #require(store.all().first)
        #expect(after.relativeFilePath == before.relativeFilePath)
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: before).path))
    }

    @Test func nilServerExtensionFallsBackToMagicGuessAndStaysZip() throws {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        try store.save(detail(id: 5, fileExtension: nil), serverID: UUID(), libraryUUID: libraryUUID,
                       libraryName: "Lib", fileExtension: "zip", fileData: zipMagic, coverData: nil)
        let before = try #require(store.all().first)

        let renamed = store.migrateFileExtensions()
        #expect(renamed == 0)

        let after = try #require(store.all().first)
        #expect(after.relativeFilePath == before.relativeFilePath)
        #expect(after.relativeFilePath.hasSuffix(".zip"))
    }

    @Test func rollsBackRenamesWhenPersistFails() throws {
        let (store, dir) = makeStore()
        defer {
            // chmod を戻してからでないと temp ディレクトリの削除に失敗しうる。
            try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                ofItemAtPath: dir.appendingPathComponent("index.json").path)
            cleanup(dir)
        }
        try store.save(detail(id: 7, fileExtension: "epub"), serverID: UUID(), libraryUUID: libraryUUID,
                       libraryName: "Lib", fileExtension: "zip", fileData: zipMagic, coverData: nil)
        let before = try #require(store.all().first)
        let beforePath = store.fileURL(for: before).path

        // index.json 自体を読み取り専用にし、正常に読める（all() は成功する）が
        // 上書き書き込み（persist の最終永続化）だけが権限エラーで失敗する状況を honest に再現する。
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
            ofItemAtPath: dir.appendingPathComponent("index.json").path)

        let renamed = store.migrateFileExtensions()
        #expect(renamed == 0)

        // ファイルは元の名前（.zip）に戻っているべきで、リネーム先（.epub）は存在しない。
        #expect(FileManager.default.fileExists(atPath: beforePath))
        let epubPath = (beforePath as NSString).deletingPathExtension + ".epub"
        #expect(!FileManager.default.fileExists(atPath: epubPath))

        // 権限を戻してから index.json を読み直し、旧パスのままであることも確認する。
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
            ofItemAtPath: dir.appendingPathComponent("index.json").path)
        let after = try #require(store.all().first)
        #expect(after.relativeFilePath == before.relativeFilePath)
    }

    @Test func secondRunIsNoOp() throws {
        let (store, dir) = makeStore()
        defer { cleanup(dir) }
        try store.save(detail(id: 6, fileExtension: "epub"), serverID: UUID(), libraryUUID: libraryUUID,
                       libraryName: "Lib", fileExtension: "zip", fileData: zipMagic, coverData: nil)

        let firstRun = store.migrateFileExtensions()
        #expect(firstRun == 1)
        let secondRun = store.migrateFileExtensions()
        #expect(secondRun == 0)
    }
}
