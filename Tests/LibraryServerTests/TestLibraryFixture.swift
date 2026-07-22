// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import StackroomFormat
import AppCore
import ImageIO
import UniformTypeIdentifiers
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

    /// G9b archive モードのフォルダ本を模す: バンドル内にディレクトリを作り、ダミー画像を
    /// `imageCount` 枚直下に置いて、その path を持つ本を insert する（file_mtime/file_size は
    /// dedup スキャンを経ないので import 直後どおり両方 NULL のまま）。
    /// フォルダ本 ETag/BookContentCache の凍結バグ再現テスト用（実機 smoke id=19 相当）。
    func addFolderBook(imageCount: Int) throws -> (id: Int, dirURL: URL) {
        let dir = bundleURL.appendingPathComponent("folder-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<imageCount {
            try Data("page\(i)".utf8).write(to: dir.appendingPathComponent("page\(i).jpg"))
        }
        let id = try db.insertBookReturningID(BookRecord(
            id: 0, title: "Folder Book", path: dir.path, dateAdded: Date()
        ))
        return (id, dir)
    }

    /// フォルダ直下に画像を1枚追加し、ディレクトリ自身の mtime を明示的に進める
    /// （テストの決定性のため OS 側の自然な mtime 更新に依存しない）。
    func addImageToFolderBook(dirURL: URL, name: String, bumpMtimeTo epoch: TimeInterval) throws {
        try Data(name.utf8).write(to: dirURL.appendingPathComponent(name))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: epoch)], ofItemAtPath: dirURL.path)
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

    /// 200x200 の JPEG を表紙として配置する（maxw 縮小テスト用: 1x1 では縮小が起きないため）。
    func addLargeCover(bookID: Int, width: Int = 200, height: Int = 200) throws {
        let dir = bundleURL.appendingPathComponent("Thumbnails/\(bookID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // CoreGraphics で width x height の solid グレー画像を生成し JPEG に変換する。
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let dest = NSMutableData()
        guard let imgDest = CGImageDestinationCreateWithData(
            dest, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(imgDest, cgImage, nil)
        guard CGImageDestinationFinalize(imgDest) else { throw CocoaError(.fileWriteUnknown) }
        try (dest as Data).write(to: dir.appendingPathComponent("thumbnail.jpg"))
    }

    /// 既存の thumbnail.jpg をサイズの異なるバイト列で上書きする（mtime+size 由来 ETag の変化検証用）。
    /// addCover の最小 JPEG に末尾バイトを足してサイズを変える（内容妥当性はテスト対象外）。
    func rewriteCover(bookID: Int) throws {
        let file = bundleURL
            .appendingPathComponent("Thumbnails/\(bookID)")
            .appendingPathComponent("thumbnail.jpg")
        var bytes: [UInt8] = [0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43, 0x00]
        bytes += [UInt8](repeating: 0x10, count: 64)
        bytes += [0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00]
        bytes += [0xFF, 0xC4, 0x00, 0x1F, 0x00]
        bytes += [UInt8](repeating: 0x00, count: 16)
        bytes += [0x0A]
        bytes += [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x7F, 0xFF, 0xD9]
        bytes += [UInt8](repeating: 0x00, count: 32)   // サイズを変えるための追加バイト
        try Data(bytes).write(to: file)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: bundleURL)
    }
}
