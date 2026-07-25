// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

public extension Notification.Name {
    /// OfflineStore の DL 済み集合が変化した（save/remove）。オフライン UI が監視して再読込する。
    static let offlineStoreDidChange = Notification.Name("StackNest.offlineStoreDidChange")
    /// ⌘⇧O 復帰要求。オフラインウィンドウが既に開いている場合に reload() を発火させ、
    /// OfflineResumeIntent.shared.pendingBookID を消費させる。
    static let offlineResumeRequested = Notification.Name("stacknest.offlineResumeRequested")
}

/// #6: `OfflineStore.save` が受け取る `libraryUUID`/`fileExtension` はリモートサーバ応答由来の
/// 文字列で、そのまま `appendingPathComponent` へ渡ってディスクパスの一部になる。悪意あるサーバが
/// `../` などを混入させると Offline ディレクトリ外へ書き込める（パストラバーサル）ため、
/// 正規の値（UUID / 英数字拡張子）以外は `save` の先頭で弾く。
public enum OfflineStoreError: Error, Equatable, Sendable, LocalizedError {
    /// `libraryUUID` が正規 UUID 文字列（8-4-4-4-12 の16進数）でない。
    case invalidLibraryUUID
    /// `fileExtension` が英数字のみ・妥当な長さの拡張子でない。
    case invalidFileExtension

    public var errorDescription: String? {
        switch self {
        case .invalidLibraryUUID: return "不正な libraryUUID です"
        case .invalidFileExtension: return "不正なファイル拡張子です"
        }
    }
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

    /// `fileExtension` として許容する最大文字数（正規の zip/cbz/pdf/jpg/png/cover 等を大きく上回る余裕値）。
    static let maxFileExtensionLength = 10

    /// 英数字のみ・妥当な長さの拡張子か（`.`/`..`/パス区切りを含まない）。
    static func isValidFileExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty, ext.count <= maxFileExtensionLength else { return false }
        return ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    public func save(_ detail: BookDetailDTO, serverID: UUID, libraryUUID: String, libraryName: String,
                     fileExtension: String, fileData: Data, coverData: Data?) throws {
        try save(detail, serverID: serverID, libraryUUID: libraryUUID, libraryName: libraryName,
                 fileExtension: fileExtension, coverData: coverData) { dest in
            try fileData.write(to: dest)
        }
    }

    /// G23 (M2): ダウンロード済みの一時ファイルを**移動して**取り込む（メモリに全量を載せない）。
    /// 取り込みに成功した場合、`fileURL` の実体は移動または削除され残らない。
    public func save(_ detail: BookDetailDTO, serverID: UUID, libraryUUID: String, libraryName: String,
                     fileExtension: String, fileURL: URL, coverData: Data?) throws {
        try save(detail, serverID: serverID, libraryUUID: libraryUUID, libraryName: libraryName,
                 fileExtension: fileExtension, coverData: coverData) { dest in
            // 同じボリュームなら move で済む。跨ボリューム等で失敗したら copy にフォールバックし、
            // 元ファイルを削除して残骸を作らない。
            do {
                try fm.moveItem(at: fileURL, to: dest)
            } catch {
                try fm.copyItem(at: fileURL, to: dest)
                try? fm.removeItem(at: fileURL)
            }
        }
    }

    /// 保存先の検証・ディレクトリ作成・目録更新を共通化し、本体の配置方法だけを差し替える。
    private func save(_ detail: BookDetailDTO, serverID: UUID, libraryUUID: String, libraryName: String,
                      fileExtension: String, coverData: Data?,
                      placeFile: (URL) throws -> Void) throws {
        // #6: 悪意あるサーバが `libraryUUID`/`fileExtension` に `../` 等を混入させて
        // Offline ディレクトリ外へ書き込むのを防ぐ（下の appendingPathComponent に渡す前に検証する）。
        guard UUID(uuidString: libraryUUID) != nil else { throw OfflineStoreError.invalidLibraryUUID }
        guard Self.isValidFileExtension(fileExtension) else { throw OfflineStoreError.invalidFileExtension }
        let dir = baseDirectory.appendingPathComponent("\(serverID.uuidString)/\(libraryUUID)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let rel = "\(serverID.uuidString)/\(libraryUUID)/\(detail.id).\(fileExtension)"
        let dest = baseDirectory.appendingPathComponent(rel)
        // 再ダウンロードの上書き時、moveItem は既存ファイルがあると失敗するため先に退ける。
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try placeFile(dest)
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

    /// 複数の DL 済を一括削除する。
    public func removeBooks(_ books: [DownloadedBook]) {
        for b in books {
            remove(serverID: b.serverID, libraryUUID: b.libraryUUID, bookID: b.bookID)
        }
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
