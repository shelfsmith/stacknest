// SPDX-License-Identifier: MIT
import Foundation
import Testing
import LibraryStore
import StackroomFormat
import AppCore
import ImageIO
import UniformTypeIdentifiers
@testable import LibraryServer

/// レジストリの実行中ジョブが終わるまで待つ（テスト後始末専用ヘルパ）。
///
/// full-scan / complete-metadata / compress-covers は `MaintenanceJobRegistry.start` が
/// 起動するバックグラウンド Task が `run` クロージャの中で fixture の DB・ファイルへ
/// 直接触れ続ける。テスト側が `defer { fx.cleanup() }` で fixture ディレクトリを消すのは
/// 「ジョブが終わっただろう」という `Task.sleep` の当てずっぽうに頼ってはならない ――
/// ジョブがまだ走っている間に消すと、消えたディレクトリ/DB に対してジョブが書き込みを
/// 試みて失敗する（テスト本体には紐付かない Task 上の失敗なので、どのテストが落ちたのか
/// 分からない「2 issues」という形でだけ suite 全体に現れる）。
/// `MaintenanceJobRegistry.status(library:)` は `run` クロージャが実際に return した後にだけ
/// nil に戻る（`start` 実装参照）ので、これが nil になるまで待てば「ジョブがもうこの
/// fixture に触れていない」ことを確定的に確認できる。
func waitForMaintenanceJobToFinish(
    registry: MaintenanceJobRegistry, library: String,
    timeout: Duration = .seconds(10)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while await registry.status(library: library) != nil {
        if ContinuousClock.now >= deadline {
            Issue.record("maintenance job for library \(library) did not finish within \(timeout) (teardown wait timed out)")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// 一時ライブラリバンドル + 任意冊数のダミー本を生成するテストヘルパ。
/// Database の open/migrate/insert は LibraryStore の実公開 API
/// （`Database.openFile(at:mode:)` / `migrate()` / `insertBook(_: BookRecord)`）を使う。
final class TestLibraryFixture: @unchecked Sendable {
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

    /// 本テスト target の zip fixture をバンドル一時領域へコピーし、その URL を返す。
    /// バンドル配下なので relink の許可ルート検証も通る（G26 relink ゲートのテストで使う）。
    @discardableResult
    func copyFixtureZip(named name: String, as fileName: String? = nil) throws -> URL {
        guard let src = Bundle.module.url(
            forResource: name, withExtension: "zip", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dst = bundleURL.appendingPathComponent(fileName ?? "\(name).zip")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    /// 本テスト target の zip fixture をバンドル一時領域へコピーし、
    /// その path を持つ本を実 insert API（`insertBookReturningID(_: BookRecord)`）で登録して id を返す。
    func addRealBook(zipFixtureNamed name: String) throws -> Int {
        let dst = try copyFixtureZip(named: name)
        return try db.insertBookReturningID(BookRecord(
            id: 0,   // insertBookReturningID は id を使わず ROWID 自動採番
            title: name,
            path: dst.path,
            dateAdded: Date()
        ))
    }

    /// G21 followup Important #2: 単独 PDF 本（アーカイブに包まれていない .pdf そのもの）を
    /// バンドルへコピーして登録する。`regenerateThumbnail` の PDF 分岐（`PDFBookContent.coverJPEG`）
    /// を単独ファイル経路で検証するためのヘルパ。
    func addPDFBook(pdfFixtureNamed name: String = "1page") throws -> Int {
        guard let src = Bundle.module.url(
            forResource: name, withExtension: "pdf", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dst = bundleURL.appendingPathComponent("\(name).pdf")
        try FileManager.default.copyItem(at: src, to: dst)
        return try db.insertBookReturningID(BookRecord(
            id: 0, title: name, path: dst.path, dateAdded: Date()
        ))
    }

    /// G21 followup Important #2: 単独画像本（.jpg そのものが 1 冊）を登録する。
    /// `regenerateThumbnail` の単独画像分岐（ファイルをそのまま読む）を検証するためのヘルパ。
    func addImageBook(width: Int = 40, height: Int = 40) throws -> Int {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        ctx.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        let dest = NSMutableData()
        guard let imgDest = CGImageDestinationCreateWithData(
            dest, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(imgDest, cgImage, nil)
        guard CGImageDestinationFinalize(imgDest) else { throw CocoaError(.fileWriteUnknown) }
        let dst = bundleURL.appendingPathComponent("standalone-\(UUID().uuidString).jpg")
        try (dest as Data).write(to: dst)
        return try db.insertBookReturningID(BookRecord(
            id: 0, title: "image book", path: dst.path, dateAdded: Date()
        ))
    }

    /// G21 followup Important #2: 表紙を作りようがない形式（動画・epub・txt 等）を模す最小ファイル。
    /// 拡張子だけで判定されるため中身はダミーで良い。
    func addUnsupportedFormatBook(extension ext: String = "txt") throws -> Int {
        let dst = bundleURL.appendingPathComponent("unsupported-\(UUID().uuidString).\(ext)")
        try Data("dummy".utf8).write(to: dst)
        return try db.insertBookReturningID(BookRecord(
            id: 0, title: "unsupported", path: dst.path, dateAdded: Date()
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

    /// G21 #6-1: テストが途中で落ちても temp を残さない。`cleanup()` の明示呼び出しは
    /// 従来どおり残すが（早期に消したいケースがある）、呼ばれなくても deinit で必ず消える。
    /// `removeItem` は `try?` なので二重削除でも安全に no-op になる。
    deinit {
        try? FileManager.default.removeItem(at: bundleURL)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: bundleURL)
    }
}
