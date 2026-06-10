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

    func cleanup() {
        try? FileManager.default.removeItem(at: bundleURL)
    }
}
