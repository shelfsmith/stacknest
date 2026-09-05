// SPDX-License-Identifier: MIT
import Foundation

/// G48-3: リモート書庫のテキスト EPUB を Washi で開くための本体ファイルのキャッシュ。
/// `<base>/<serverID>/<libraryUUID>/<bookID>.epub`。既にあれば再取得しない(etag 失効は G48-3 では付けない・spec §6)。
public struct RemoteEPUBCache: Sendable {
    public let baseDirectory: URL
    public init(baseDirectory: URL) { self.baseDirectory = baseDirectory }
    public init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let bundle = Bundle.main.bundleIdentifier ?? "StackNest"
        self.init(baseDirectory: caches.appendingPathComponent(bundle).appendingPathComponent("remote-epub"))
    }
    /// `version` はサーバの manifest の etag（本の差し替えで変わる）。最終レビュー I3: spec §2 は
    /// 「版が無い」としていたが manifest.etag が取得済みなので、ファイル名に織り込んで失効させる。
    public func fileURL(serverID: UUID, libraryUUID: String, bookID: Int, version: String? = nil) -> URL {
        let name = Self.versionTag(version).map { "\(bookID)-\($0).epub" } ?? "\(bookID).epub"
        return baseDirectory.appendingPathComponent(serverID.uuidString).appendingPathComponent(libraryUUID).appendingPathComponent(name)
    }
    /// etag（引用符付き・弱 ETag など）をファイル名に使える形に正規化する。空なら nil。
    static func versionTag(_ version: String?) -> String? {
        guard let version else { return nil }
        let t = version.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        return t.isEmpty ? nil : String(t.prefix(64))
    }
    /// ダウンロード済み一時ファイルをキャッシュ位置へ move し、上限を超えた古いものを消す。
    public func store(temporaryFile: URL, serverID: UUID, libraryUUID: String, bookID: Int, version: String? = nil, keep: Int = 32) throws -> URL {
        // 最終レビュー Minor: 失敗しても一時ファイルを残さない
        defer { if FileManager.default.fileExists(atPath: temporaryFile.path) { try? FileManager.default.removeItem(at: temporaryFile) } }
        let dest = fileURL(serverID: serverID, libraryUUID: libraryUUID, bookID: bookID, version: version)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: temporaryFile, to: dest)
        prune(keep: keep)
        return dest
    }
    /// 全サーバ・全ライブラリを通して、更新日時の新しい `keep` 件だけ残す。失敗は無視(キャッシュなので)。
    public func prune(keep: Int = 32) {
        guard let e = FileManager.default.enumerator(at: baseDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        var files: [(URL, Date)] = []
        for case let u as URL in e {
            guard u.pathExtension == "epub", (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            files.append((u, m))
        }
        guard files.count > keep else { return }
        for (u, _) in files.sorted(by: { $0.1 < $1.1 }).prefix(files.count - keep) { try? FileManager.default.removeItem(at: u) }
    }
}
