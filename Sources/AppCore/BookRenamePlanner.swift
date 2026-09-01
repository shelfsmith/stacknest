// SPDX-License-Identifier: MIT
import Foundation
import StackroomFormat
import LibraryStore  // TextNormalize

/// 1 冊分の改名の見立て。
public enum RenameStatus: String, Equatable, Sendable, Codable {
    case ok                 // 改名する
    case unchanged          // 既に同じ名前
    case conflictExisting   // 同名のファイルが実在する
    case conflictInBatch    // 同じ回の中で新しい名前がぶつかる
    case emptyName          // 全トークンが空で名前が作れない
    case tooLong            // 255 バイトを超える
    case noPath             // path が無い（未リンク）
    case missingFile        // 元のファイルが見つからない（リンク切れ）
}

public struct RenamePlanRow: Equatable, Sendable {
    public let id: Int
    public let oldPath: String
    /// 名前を作れなかったときは空文字。
    public let newPath: String
    public let oldName: String
    public let newName: String
    public let status: RenameStatus

    public init(id: Int, oldPath: String, newPath: String,
                oldName: String, newName: String, status: RenameStatus) {
        self.id = id; self.oldPath = oldPath; self.newPath = newPath
        self.oldName = oldName; self.newName = newName; self.status = status
    }

    /// 大文字小文字だけが違う改名か（実行側が一時名を経由する必要がある）。
    public var isCaseOnlyRename: Bool {
        !oldPath.isEmpty && !newPath.isEmpty && oldPath != newPath
            && oldPath.lowercased() == newPath.lowercased()
    }
}

/// **改名の判断はすべてここに置く。**
///
/// ディスクも DB も触らない。`fileExists` を注入するのはテストのため。
/// GUI のシートと `POST /local/libraries/:uuid/rename-files` の**両方がこれを呼ぶ** ——
/// 2 箇所に書くと「プレビューと実際の改名が食い違う」という一番まずい壊れ方をする。
public enum BookRenamePlanner {
    /// ファイル名 1 要素の上限（バイト）。macOS の実際の上限。
    public static let maxNameBytes = 255

    public static func plan(
        books: [BookRecord],
        format: FilenameFormat,
        bookTypeLabels: [Int: String],
        volumeWidths: [String: Int],
        /// 元のファイルが実在するかを見る。**既定は「実在する」** ——
        /// 既存の呼び出しとテストの意味を変えないため。実運用では FileManager を渡す。
        oldFileExists: (String) -> Bool = { _ in true },
        fileExists: (String) -> Bool
    ) -> [RenamePlanRow] {
        var claimed: Set<String> = []   // この回で既に使われた新パス（小文字化して比較）
        var rows: [RenamePlanRow] = []

        for book in books {
            guard let rawPath = book.path, !rawPath.isEmpty else {
                rows.append(RenamePlanRow(id: book.id, oldPath: book.path ?? "", newPath: "",
                                          oldName: "", newName: "", status: .noPath))
                continue
            }
            guard oldFileExists(rawPath) else {
                let oldName = URL(fileURLWithPath: rawPath).lastPathComponent
                rows.append(RenamePlanRow(id: book.id, oldPath: rawPath, newPath: "",
                                          oldName: oldName, newName: "", status: .missingFile))
                continue
            }
            let url = URL(fileURLWithPath: rawPath)
            let oldName = url.lastPathComponent
            let ext = url.pathExtension

            let width = volumeWidths[TextNormalize.nfc(book.series ?? "")] ?? VolumeWidth.minimum
            let base = stripLeadingDots(
                FilenameFormatter.format(book, with: format,
                                         bookTypeLabels: bookTypeLabels, volumeWidth: width))

            guard !base.isEmpty else {
                rows.append(RenamePlanRow(id: book.id, oldPath: rawPath, newPath: "",
                                          oldName: oldName, newName: "", status: .emptyName))
                continue
            }

            let newName = ext.isEmpty ? base : base + "." + ext
            guard newName.utf8.count <= maxNameBytes else {
                rows.append(RenamePlanRow(id: book.id, oldPath: rawPath, newPath: "",
                                          oldName: oldName, newName: newName, status: .tooLong))
                continue
            }

            let newPath = url.deletingLastPathComponent().appendingPathComponent(newName).path
            let status: RenameStatus
            if newPath == rawPath {
                status = .unchanged
            } else if !claimed.insert(newPath.lowercased()).inserted {
                status = .conflictInBatch
            } else if fileExists(newPath) && newPath.lowercased() != rawPath.lowercased() {
                // 大文字小文字だけが違うときの fileExists は「自分自身」を指している。
                // ここで弾くと、大文字小文字だけの改名が黙ってスキップされる。
                status = .conflictExisting
            } else {
                status = .ok
            }
            rows.append(RenamePlanRow(id: book.id, oldPath: rawPath, newPath: newPath,
                                      oldName: oldName, newName: newName, status: status))
        }
        return rows
    }

    /// **`apply` が false なら空を返す。**
    ///
    /// これは二重の守りで、呼び出し側（`LocalControlController.renameFiles`）にも
    /// 早期 return がある。**単体で試験できる場所に置くのが目的** ――
    /// コントローラは `AppState` を要するので、そちらの分岐は自動テストが届かない。
    public static func rowsToApply(plan: [RenamePlanRow], apply: Bool) -> [RenamePlanRow] {
        apply ? plan.filter { $0.status == .ok } : []
    }

    /// 先頭のドットと空白を落とす（隠しファイルを作らない）。
    /// **空白を挟んだドット（". . x"）も落とす** —— ドットだけを見て止めると、
    /// 落とした後にまたドットが現れて隠しファイルになる。
    static func stripLeadingDots(_ s: String) -> String {
        var out = Substring(s)
        while let f = out.first, f == "." || f == " " || f == "\u{3000}" {
            out = out.dropFirst()
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}
