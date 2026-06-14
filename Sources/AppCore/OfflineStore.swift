// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

public extension Notification.Name {
    /// OfflineStore の DL 済み集合が変化した（save/remove）。オフライン UI が監視して再読込する。
    static let offlineStoreDidChange = Notification.Name("StackNest.offlineStoreDidChange")
}

public struct DownloadedBook: Codable, Sendable, Identifiable {
    public var detail: BookDetailDTO
    public var serverID: UUID
    public var libraryUUID: String
    public var libraryName: String
    public var relativeFilePath: String
    public var hasCachedCover: Bool
    public var downloadedAt: Date
    public var lastPage: Int?
    public var bookID: Int { detail.id }
    public var id: String { "\(serverID.uuidString)/\(libraryUUID)/\(detail.id)" }
    public init(detail: BookDetailDTO, serverID: UUID, libraryUUID: String, libraryName: String,
                relativeFilePath: String, hasCachedCover: Bool, downloadedAt: Date, lastPage: Int?) {
        self.detail = detail; self.serverID = serverID; self.libraryUUID = libraryUUID
        self.libraryName = libraryName; self.relativeFilePath = relativeFilePath
        self.hasCachedCover = hasCachedCover; self.downloadedAt = downloadedAt; self.lastPage = lastPage
    }
}

/// 注: @unchecked Sendable。呼び出しは現状すべて @MainActor 経由（downloadBook / persistState）で
/// 直列化されているため競合しない。並行呼び出しを足す場合は actor 化を検討。
public struct OfflineStore: @unchecked Sendable {
    public let baseDirectory: URL
    private var indexURL: URL { baseDirectory.appendingPathComponent("index.json") }
    private let fm = FileManager.default

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory { self.baseDirectory = baseDirectory }
        else {
            let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.baseDirectory = appSup.appendingPathComponent("StackNest/Offline", isDirectory: true)
        }
    }

    public func all() -> [DownloadedBook] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? decoder().decode([DownloadedBook].self, from: data) else { return [] }
        return list
    }

    public func save(_ detail: BookDetailDTO, serverID: UUID, libraryUUID: String, libraryName: String,
                     fileExtension: String, fileData: Data, coverData: Data?) throws {
        let dir = baseDirectory.appendingPathComponent("\(serverID.uuidString)/\(libraryUUID)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let rel = "\(serverID.uuidString)/\(libraryUUID)/\(detail.id).\(fileExtension)"
        try fileData.write(to: baseDirectory.appendingPathComponent(rel))
        var hasCover = false
        if let coverData {
            try coverData.write(to: dir.appendingPathComponent("\(detail.id).cover"))
            hasCover = true
        }
        let book = DownloadedBook(detail: detail, serverID: serverID, libraryUUID: libraryUUID,
                                  libraryName: libraryName, relativeFilePath: rel, hasCachedCover: hasCover,
                                  downloadedAt: Date(), lastPage: nil)
        var list = all().filter { !($0.serverID == serverID && $0.libraryUUID == libraryUUID && $0.detail.id == detail.id) }
        list.append(book)
        try persist(list)
        NotificationCenter.default.post(name: .offlineStoreDidChange, object: nil)
    }

    public func fileURL(for book: DownloadedBook) -> URL { baseDirectory.appendingPathComponent(book.relativeFilePath) }
    public func coverURL(for book: DownloadedBook) -> URL {
        baseDirectory.appendingPathComponent("\(book.serverID.uuidString)/\(book.libraryUUID)/\(book.detail.id).cover")
    }

    public func remove(serverID: UUID, libraryUUID: String, bookID: Int) {
        if let book = all().first(where: { $0.serverID == serverID && $0.libraryUUID == libraryUUID && $0.detail.id == bookID }) {
            try? fm.removeItem(at: fileURL(for: book))
            if book.hasCachedCover { try? fm.removeItem(at: coverURL(for: book)) }
        }
        try? persist(all().filter { !($0.serverID == serverID && $0.libraryUUID == libraryUUID && $0.detail.id == bookID) })
        NotificationCenter.default.post(name: .offlineStoreDidChange, object: nil)
    }

    public func updateLastPage(serverID: UUID, libraryUUID: String, bookID: Int, page: Int) {
        var list = all()
        if let i = list.firstIndex(where: { $0.serverID == serverID && $0.libraryUUID == libraryUUID && $0.detail.id == bookID }) {
            list[i].lastPage = page
            try? persist(list)
        }
    }

    public func isDownloaded(serverID: UUID, libraryUUID: String, bookID: Int) -> Bool {
        all().contains { $0.serverID == serverID && $0.libraryUUID == libraryUUID && $0.detail.id == bookID }
    }

    public enum AdjacentDirection { case next, prev }

    /// 同一 server/library/series で **連続する次/前の巻番号**（next=現在+1・prev=現在-1）が
    /// DL 済ならその本を返す。連続巻が未 DL なら nil（=停止・ギャップスキップはしない）。
    /// オフラインは全カタログを持たないため保守的に連続巻のみを対象とする。
    public func adjacentDownloaded(serverID: UUID, libraryUUID: String, series: String,
                                   volume: Double, direction: AdjacentDirection) -> DownloadedBook? {
        guard !series.isEmpty else { return nil }
        let target = (direction == .next) ? volume + 1 : volume - 1
        return all().first {
            $0.serverID == serverID && $0.libraryUUID == libraryUUID
            && ($0.detail.series ?? "") == series
            && $0.detail.volume == target
        }
    }

    public func totalSizeBytes() -> Int64 {
        all().reduce(0) { acc, b in
            let sz = (try? fileURL(for: b).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + Int64(sz ?? 0)
        }
    }

    private func persist(_ list: [DownloadedBook]) throws {
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try encoder().encode(list).write(to: indexURL)
    }
    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
