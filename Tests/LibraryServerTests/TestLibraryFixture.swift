// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import StackroomFormat
import AppCore
@testable import LibraryServer

/// 一時ライブラリバンドル + 任意冊数のダミー本を生成するテストヘルパ。
/// Database の open/migrate/insert は LibraryStore の実公開 API
/// （`Database.openFile(at:mode:)` / `migrate()` / `insertBook(_: BookRecord)`）を使う。
struct TestLibraryFixture {
    let bundleURL: URL
    let db: Database
    let name: String

    init(name: String, bookCount: Int, locked: Bool = false, password: String = "") throws {
        self.name = name
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lsrv-\(UUID().uuidString).stacknest")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.bundleURL = dir
        // LibraryBundle 規約に従い library.sqlite を作成して migrate
        self.db = try Database.openFile(
            at: dir.appendingPathComponent("library.sqlite"), mode: .createOrFail)
        try db.migrate()
        if bookCount > 0 {
            for i in 1...bookCount {
                try db.insertBook(BookRecord(
                    id: i,
                    title: "Book \(i)",
                    dateAdded: Date(),
                    myRate: i % 6,
                    series: "S",
                    volume: Double(i)
                ))
            }
        }
        if locked {
            let salt = LibraryLock.generateSalt()
            let hash = LibraryLock.computeHash(password: password, saltHex: salt)
            try db.setLibrarySetting(key: "lock_password_hash", value: hash)
            try db.setLibrarySetting(key: "lock_password_salt", value: salt)
        }
    }

    func servedLibrary() -> ServedLibrary {
        let uuid = (try? db.getLibrarySetting(key: "library_uuid"))
            .flatMap { $0 }
            ?? {
                let u = UUID().uuidString
                try? db.setLibrarySetting(key: "library_uuid", value: u)
                return u
            }()
        let locked = ((try? db.getLibrarySetting(key: "lock_password_hash")) ?? nil) != nil
        return ServedLibrary(uuid: uuid, name: name, bundleURL: bundleURL, db: db, isLocked: locked)
    }

    /// 本テスト target の zip fixture をバンドル一時領域へコピーし、
    /// その path を持つ本を実 insert API（`insertBookReturningID(_: BookRecord)`）で登録して id を返す。
    func addRealBook(zipFixtureNamed name: String) throws -> Int {
        guard let src = Bundle.module.url(
            forResource: name, withExtension: "zip", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dst = bundleURL.appendingPathComponent("\(name).zip")
        try FileManager.default.copyItem(at: src, to: dst)
        return try db.insertBookReturningID(BookRecord(
            id: 0,   // insertBookReturningID は id を使わず ROWID 自動採番
            title: name,
            path: dst.path,
            dateAdded: Date()
        ))
    }

    /// 最小 JPEG を実規約どおり `Thumbnails/<bookID>/thumbnail.jpg` に書く。
    /// 実コード（CoverRefresher / ThumbnailLoader）の規約はファイル名固定 `thumbnail.jpg` で、
    /// `coverImageName` はアーカイブ内エントリ名（手動表紙の選択記録）であり
    /// ディスク上のファイル名ではないため、DB 更新は行わない。
    func addCover(bookID: Int) throws {
        let dir = bundleURL.appendingPathComponent("Thumbnails/\(bookID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 1x1 JPEG の固定バイト列（テスト用・SOI..EOI）。
        // 一括連結は swiftc の型推論が破綻するため段階的に組み立てる。
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43, 0x00]
        bytes += [UInt8](repeating: 0x10, count: 64)
        bytes += [0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00]
        bytes += [0xFF, 0xC4, 0x00, 0x1F, 0x00]
        bytes += [UInt8](repeating: 0x00, count: 16)
        bytes += [0x0A]
        bytes += [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x7F, 0xFF, 0xD9]
        try Data(bytes).write(to: dir.appendingPathComponent("thumbnail.jpg"))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: bundleURL)
    }
}
