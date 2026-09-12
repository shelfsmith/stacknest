// SPDX-License-Identifier: MIT
import Foundation

/// G54-S2: オフラインの実体は `<bookID>.<拡張子>` という名前なので、
/// 外部ビューアの窓には書庫の番号が出て、何を開いているか読めない。
/// 渡す直前に**題名のハードリンク**を作り、そのパスを渡す。実体は複製しないので、
/// 動画のように大きいものでも容量と時間を食わない。
///
/// 置き場は `<OfflineStore.baseDirectory>/_external/<serverID>/<libraryUUID>/<bookID>/<題名>.<拡張子>`。
/// **実体の並びをそのまま写している。**`BookDetailDTO.id` は庫ごとの連番なので、
/// 番号だけで小部屋を掘ると別のサーバや別の庫の同じ番号とぶつかる。
/// `OfflineStore` は `baseDirectory` を走査しないので、`_external` を置いても索引の読み書きに触らない。
public struct OfflineExternalLink: Sendable {
    /// リンクを置く根。
    public let root: URL
    private var fm: FileManager { FileManager.default }

    public init(baseDirectory: URL) {
        self.root = baseDirectory.appendingPathComponent("_external", isDirectory: true)
    }

    /// 小部屋の鍵。実体と同じ `<serverID>/<libraryUUID>/<bookID>`。
    /// `DownloadedBook.id` が既にこの形をしている。
    public static func roomKey(for book: DownloadedBook) -> String { book.id }

    /// 題名からファイル名を作る。
    /// - パス区切りとコロンを `-` に置換する（ディレクトリを掘られないため）。
    /// - 制御文字を落とす。
    /// - 先頭のドットを `_` に置換する（隠しファイルにしないため）。
    /// - UTF-8 で 200 バイトに詰める（拡張子と合わせて 255 バイトに収める）。
    /// - 空になったら書庫の番号に落とす。
    public static func safeFileName(title: String, fallbackID: Int, fileExtension: String) -> String {
        var name = title.replacingOccurrences(of: "/", with: "-")
                        .replacingOccurrences(of: ":", with: "-")
        name = String(String.UnicodeScalarView(
            name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name = "_" + name.dropFirst() }
        name = truncated(name, toUTF8Bytes: 200)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "\(fallbackID)" }
        return fileExtension.isEmpty ? name : "\(name).\(fileExtension)"
    }

    /// 文字の途中で切らずに UTF-8 のバイト数で詰める。
    private static func truncated(_ s: String, toUTF8Bytes limit: Int) -> String {
        var out = ""
        var used = 0
        for ch in s {
            let n = String(ch).utf8.count
            if used + n > limit { break }
            out.append(ch)
            used += n
        }
        return out
    }

    /// 題名のリンクを作り、外部ビューアへ渡す URL を返す。
    /// 作れなければ**実体の URL を返す**（開けないより名前が汚い方が軽い）。
    public func linkURL(for book: DownloadedBook, fileURL: URL) -> URL {
        let room = root.appendingPathComponent(Self.roomKey(for: book), isDirectory: true)
        let name = Self.safeFileName(title: book.detail.title, fallbackID: book.bookID,
                                     fileExtension: fileURL.pathExtension)
        let dest = room.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: room, withIntermediateDirectories: true)
            // 作り直す。拡張子の補正（OfflineStore.migrateFileExtensions）や改題で実体が変わっても
            // 古いリンクを残さない。小部屋は 1 冊ぶんしか持たないので、中身は全部落としてよい。
            for f in (try? fm.contentsOfDirectory(atPath: room.path)) ?? [] {
                try? fm.removeItem(at: room.appendingPathComponent(f))
            }
            try fm.linkItem(at: fileURL, to: dest)
            return dest
        } catch {
            return fileURL
        }
    }

    /// 1 冊ぶんの小部屋を消す。オフラインから削除したときに呼ぶ。
    /// ハードリンクが残っている間は実体を消しても容量が戻らないため、削除と対で呼ぶ必要がある。
    public func removeRoom(for book: DownloadedBook) {
        try? fm.removeItem(at: root.appendingPathComponent(Self.roomKey(for: book), isDirectory: true))
    }

    /// 索引に在る本の小部屋だけ残し、他を消す。起動時に呼ぶ。
    public func prune(keeping rooms: Set<String>) {
        guard fm.fileExists(atPath: root.path) else { return }
        for server in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let serverURL = root.appendingPathComponent(server, isDirectory: true)
            for library in (try? fm.contentsOfDirectory(atPath: serverURL.path)) ?? [] {
                let libraryURL = serverURL.appendingPathComponent(library, isDirectory: true)
                for bookID in (try? fm.contentsOfDirectory(atPath: libraryURL.path)) ?? [] {
                    guard !rooms.contains("\(server)/\(library)/\(bookID)") else { continue }
                    try? fm.removeItem(at: libraryURL.appendingPathComponent(bookID))
                }
                if ((try? fm.contentsOfDirectory(atPath: libraryURL.path)) ?? []).isEmpty {
                    try? fm.removeItem(at: libraryURL)
                }
            }
            if ((try? fm.contentsOfDirectory(atPath: serverURL.path)) ?? []).isEmpty {
                try? fm.removeItem(at: serverURL)
            }
        }
    }
}
