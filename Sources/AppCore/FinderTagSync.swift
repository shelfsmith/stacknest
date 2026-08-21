// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

/// 1 回の同期で何が起きたか。
public struct FinderTagSyncReport: Sendable, Equatable {
    /// StackNest 側（メタデータ項目）を書き換えた本の数。
    public let updatedInLibrary: Int
    /// Finder 側（xattr）を書き換えた本の数。
    public let updatedInFinder: Int
    /// 区切り文字（`", "`）を含むため同期対象から外したタグ名（重複なし・出現順）。
    public let skippedTags: [String]
    /// 諦めた本のパス（タグの plist が壊れている / ファイルが見つからない）。
    public let skippedBooks: [String]
    /// Spotlight 索引が無効だったため Finder → StackNest 方向を実行しなかった。
    public let indexingDisabled: Bool

    public init(updatedInLibrary: Int, updatedInFinder: Int,
                skippedTags: [String], skippedBooks: [String], indexingDisabled: Bool) {
        self.updatedInLibrary = updatedInLibrary
        self.updatedInFinder = updatedInFinder
        self.skippedTags = skippedTags
        self.skippedBooks = skippedBooks
        self.indexingDisabled = indexingDisabled
    }
}

public enum FinderTagSyncError: Error, Equatable {
    /// 同期対象にできない項目。**何もせずに投げる**（spec §2 の whitelist）。
    case unsupportedField(String)
    /// 庫のボリュームが見当たらない（未マウント等）。
    ///
    /// **黙って「全件スキップ」にしてはいけない。**全ての本が「Finder 側にタグ無し」に
    /// 見える状態と区別が付かず、spec §4.5 が警告する事故と同型になる。
    case volumeUnavailable(String)
}

/// Finder タグと StackNest のメタデータ項目 1 つを双方向に同期する（spec §4）。
///
/// ## この型の中心にある不変条件
///
/// > **`mdfind` が返さなかったことを「タグが無い証拠」にしない。**
///
/// 「Finder 側にタグが無い」と誤認する経路は 3 つある（spec §4.5）——
/// `setxattr` の置換中に読んだ（実測 18/500）、索引が無効なのに有効と誤判定した、
/// 索引の反映が遅れている。下 2 つは**庫じゅうの本が一度に「タグ無し」に見える**。
/// そのまま 3 方向マージに掛けると「ユーザーが全部消した」と解釈され、**非可逆に消える**。
///
/// 対策はひとつ: **その本に触る前に、xattr を直接読み直す。**
/// 具体的には `sync` は次を守る ——
///
/// - **Finder 側を直接読んだ本しか書き換えない**（DB も・ファイルも・前回同期値も）。
///   `mdfind` の不在から組み立てた「空集合」は、何かを変える根拠には使わない
/// - 直読みは「何かが変わりそうな本」でだけ走るので、全件のコストはほぼ変わらない
///   （タグを消す操作も、項目を編集する操作もまれ）
/// - 索引が無効なら Finder → StackNest 方向はそもそも実行しない（spec §3.3）。
///   **全件 xattr 読みへのフォールバックはしない** —— 12,000 冊で「庫を開くたびに待たされる」
public enum FinderTagSync {
    /// 同期対象にできるメタデータ項目（`Database` の browse whitelist と一致・spec §2）。
    public static let syncableFields: Set<String> = [
        "genre", "series", "author", "neta", "keyword_a", "keyword_b", "keyword_c",
    ]

    /// 「いま保存されている前回同期値は、どの項目に対するものか」を覚えておくキー。
    /// ユーザーが選んだ項目そのもの（Task 7 が持つ設定）とは別に持つ。
    static let baselineFieldKey = "finderTagBaselineField"

    public static func sync(
        database: Database,
        volume: URL,
        field: String,
        isIndexingEnabled: (URL) -> Bool = { SpotlightTagQuery.isIndexingEnabled(volume: $0) },
        taggedPaths: (URL) throws -> [String] = { try SpotlightTagQuery.taggedPaths(in: $0) }
    ) throws -> FinderTagSyncReport {
        guard syncableFields.contains(field) else {
            throw FinderTagSyncError.unsupportedField(field)
        }
        guard FileManager.default.fileExists(atPath: volume.path) else {
            throw FinderTagSyncError.volumeUnavailable(volume.path)
        }

        // 同期対象の項目が前回と違うなら、前回同期値は**別項目の値**なので無効。
        // 残したまま切り替えると、実在しない削除を検出して大量に消しかねない（spec §4.2）。
        if try database.getLibrarySetting(key: baselineFieldKey) != field {
            try database.clearAllFinderTagBaselines()
            try database.setLibrarySetting(key: baselineFieldKey, value: field)
        }

        let indexingEnabled = isIndexingEnabled(volume)
        // 索引が無効なら `mdfind` は呼ばない（呼んでも exit 0 で空を返すだけで、
        // 「本当に 0 件」と区別が付かない）。
        let tagged: Set<String> = indexingEnabled
            ? Set(try taggedPaths(volume).map(normalize)) : []

        var updatedInLibrary = 0
        var updatedInFinder = 0
        var skippedTags: [String] = []
        var seenSkippedTag: Set<String> = []
        var skippedBooks: [String] = []
        // 前回同期値は**入口で 1 クエリ**、書き戻しは**最後に 1 トランザクション**。
        // 1 冊ずつ触ると 12,000 冊で読み 2.8 秒・書き 6.8 秒（実測）掛かり、
        // spec §7 の「庫を開いても体感で待たされない」を満たせない。
        // キーが無い = NULL = 未同期（`""` = 前回 0 件 とは意味が違う）。
        let baselines = try database.finderTagBaselines()
        var pendingBaselines: [Int: String] = [:]

        do {
            for row in try database.fetchAllBooks() {
                guard let rawPath = row.path, !rawPath.isEmpty else { continue }
                let url = URL(fileURLWithPath: rawPath)
                let libraryOrder = MultiValueParser.split(value(of: field, in: row) ?? "")
                let library = Set(libraryOrder)
                // 文字列の比較は `==` / `Set` で行う（Swift の String は正準等価なので
                // NFD/NFC 混在でも一致する）。**バイト列で比べてはいけない。**
                let baseline = baselines[row.id].map { Set(MultiValueParser.split($0)) }

                /// 直読みした結果から同期対象の名前を取り出す。同期しない名前は報告に載せる。
                func syncableNames(_ entries: [FinderTagEntry]) -> Set<String> {
                    var names: Set<String> = []
                    for e in entries {
                        if FinderTagEntry.isSyncable(e.name) {
                            names.insert(e.name)
                        } else if !e.name.isEmpty, seenSkippedTag.insert(e.name).inserted {
                            // 区切り文字を含むタグ（spec §4.4）。**同じ本の他のタグは妨げない。**
                            skippedTags.append(e.name)
                        }
                    }
                    return names
                }

                /// その本の Finder タグを直接読む。壊れた plist / ファイル不在はその本だけ諦める。
                /// **それ以外のエラー（EACCES 等）は握り潰さない**（spec §4.6）——
                /// 全件が無言でスキップされると §4.5 と同型の事故になる。
                func readDirectly() throws -> Set<String>? {
                    guard FileManager.default.fileExists(atPath: rawPath) else {
                        skippedBooks.append(rawPath)
                        return nil
                    }
                    do {
                        return syncableNames(try FinderTagStore.read(at: url))
                    } catch FinderTagError.corruptedPlist {
                        skippedBooks.append(rawPath)
                        return nil
                    }
                }

                /// Finder 側へ書き戻す。戻り値は成功したか。
                func writeToFinder(_ names: Set<String>) throws -> Bool {
                    do {
                        try FinderTagStore.apply(names: names, to: url)
                        return true
                    } catch FinderTagError.corruptedPlist {
                        skippedBooks.append(rawPath)
                        return false
                    }
                }

                /// 前回同期値の更新は**変わったものだけ**溜めて、最後にまとめて書く。
                func rememberBaseline(_ names: Set<String>) {
                    guard baseline != names else { return }
                    pendingBaselines[row.id] = MultiValueParser.join(ordered(names, preferring: libraryOrder))
                }

                if !indexingEnabled {
                    // 索引が無効: Finder 側は「空」ではなく**「不明」**。
                    // Finder → StackNest 方向は実行しない（spec §3.3）。
                    // StackNest 側が前回同期から変わった本だけ書き戻す ——
                    // ここで全件を読みに行くと、避けたかった「庫を開くたびに待たされる」になる。
                    if (baseline ?? []) == library { continue }
                    guard let finder = try readDirectly() else { continue }
                    let result = FinderTagMerge.merge(baseline: baseline, finder: finder, library: library)
                    if result.changedInFinder {
                        guard try writeToFinder(result.merged) else { continue }
                        updatedInFinder += 1
                    }
                    // StackNest 側は触らない（この方向は無効）。前回同期値は**StackNest 側の値**にする。
                    // merged にすると、Finder にしか無いタグを「StackNest が持っていた」ことにして
                    // しまい、索引が戻ったときに削除と読まれて Finder から消える。
                    rememberBaseline(library)
                    continue
                }

                // ここから索引が有効な経路。
                // `finder == nil` は「**直接読んでいない**」の意。`mdfind` が返さなかったことは
                // 「タグが無い」ではない（spec §4.5）ので、空集合として扱ってよいのは
                // 「何も変わらない」と分かるときだけ。
                var finder: Set<String>?
                if tagged.contains(normalize(rawPath)) {
                    guard let read = try readDirectly() else { continue }
                    finder = read
                }
                var result = FinderTagMerge.merge(baseline: baseline, finder: finder ?? [], library: library)
                if finder == nil, result.changedInFinder || result.changedInLibrary {
                    // ★ 何かを変えようとしている。その根拠が `mdfind` の不在だけなら、
                    // **消す前に本人に直接聞く。**空が続けば本物の削除。
                    guard let read = try readDirectly() else { continue }
                    finder = read
                    result = FinderTagMerge.merge(baseline: baseline, finder: read, library: library)
                }
                // 直接読んでいない本は、この時点で「何も変わらない」と分かっている。
                // 前回同期値も含めて**一切触らない**（触ってよい根拠が無い）。
                guard finder != nil else { continue }

                if result.changedInFinder {
                    guard try writeToFinder(result.merged) else { continue }
                    updatedInFinder += 1
                }
                if result.changedInLibrary {
                    try database.updateBook(id: row.id, patch: patch(field, MultiValueParser.join(
                        ordered(result.merged, preferring: libraryOrder))))
                    updatedInLibrary += 1
                }
                rememberBaseline(result.merged)
            }
        } catch {
            // 途中で投げても、そこまでに確定した前回同期値は落とさない
            // （ファイルと DB は既に書き換わっている。前回同期値だけ古いままだと、
            // 次回の 3 方向マージが実在しない削除を見る）。
            try? database.setFinderTagBaselines(pendingBaselines)
            throw error
        }
        try database.setFinderTagBaselines(pendingBaselines)

        return FinderTagSyncReport(updatedInLibrary: updatedInLibrary,
                                   updatedInFinder: updatedInFinder,
                                   skippedTags: skippedTags,
                                   skippedBooks: skippedBooks,
                                   indexingDisabled: !indexingEnabled)
    }

    // MARK: - 補助

    /// `mdfind` の出力と DB の `path` を突き合わせるための最小限の正規化。
    /// **シンボリックリンクは解決しない** —— 全件に `realpath` を掛けると規模非依存という
    /// 利点が消える。末尾の `/`（フォルダの本で付きうる）だけ落とす。
    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 既存の並びを保ったまま、増えた分だけ末尾に足す。
    /// `FinderTagStore.apply` と同じ方針 —— 並び順はユーザーのデータで、こちらが決めてよい値ではない。
    static func ordered(_ names: Set<String>, preferring existing: [String]) -> [String] {
        var out = existing.filter { names.contains($0) }
        out += names.subtracting(existing).sorted()
        return out
    }

    static func value(of field: String, in row: BookRow) -> String? {
        switch field {
        case "genre":     return row.genre
        case "series":    return row.series
        case "author":    return row.author
        case "neta":      return row.neta
        case "keyword_a": return row.keywordA
        case "keyword_b": return row.keywordB
        case "keyword_c": return row.keywordC
        default:          return nil
        }
    }

    static func patch(_ field: String, _ value: String) -> BookPatch {
        switch field {
        case "genre":     return BookPatch(genre: value)
        // series だけ NULL 許容の単一値列。空文字を書くと「空文字という値」が残り、
        // ファセットに空欄が並ぶので、明示的にクリアする。
        case "series":    return value.isEmpty ? BookPatch(clearSeries: true) : BookPatch(series: value)
        case "author":    return BookPatch(author: value)
        case "neta":      return BookPatch(neta: value)
        case "keyword_a": return BookPatch(keywordA: value)
        case "keyword_b": return BookPatch(keywordB: value)
        case "keyword_c": return BookPatch(keywordC: value)
        default:          return BookPatch()
        }
    }
}
