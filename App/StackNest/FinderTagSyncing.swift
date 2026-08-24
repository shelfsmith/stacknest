// SPDX-License-Identifier: MIT
import Foundation
import SwiftUI
import AppKit
import AppCore
import LibraryStore

// Phase G39 Task 7: `FinderTagSync`（Sources/AppCore）を **アプリから使えるように配線する層**。
//
// この層が持つ責務は 4 つだけで、同期そのもののロジックは一切持たない:
//   1. 「どの項目を同期するか」という**庫ごとの設定**を読み書きする（`FinderTagSyncSetting`）
//   2. `mdfind` / `mdutil` に渡す**ボリュームの根**を本のパスから求める（`FinderTagVolumes`）
//   3. 複数ボリュームに跨る庫のために `FinderTagSync.sync` を**ボリュームごとに 1 回ずつ**回し、
//      結果をまとめる（`FinderTagSyncRunner`）
//   4. まとめた結果を**ユーザーに見せる文言**に落とす（`FinderTagSyncNotice`）
//
// 1〜4 はいずれも純粋（または DB だけ）なので App 層のテストで固定できる。
// 実際の起動（バックグラウンド実行・二重起動の抑止）は `AppState+FinderTags.swift`。

// MARK: - 庫ごとの設定

/// 「この庫はどのメタデータ項目を Finder タグと同期するか」（spec §1: 庫ごとに 1 項目・未設定＝同期しない）。
enum FinderTagSyncSetting {
    /// `library_settings` のキー。**`FinderTagSync` が内部で使う `finderTagBaselineField`
    /// （前回同期値がどの項目のものかの記録）とは別物**なので混同しないこと。
    static let key = "finderTagSyncField"

    /// UI に並べる選択肢（順序付き）。`BrowseField` の 7 項目は
    /// `FinderTagSync.syncableFields`（集合）と同じ内容で、こちらは順序を持つ。
    /// 両者が食い違っていないことは `FinderTagSyncSettingTests` が固定している。
    static let fields: [String] = BrowserPaneState.BrowseField.allCases.map(\.sqlColumn)

    /// 保存されている値を「同期対象の項目」として解釈する。
    /// **未設定・空文字・whitelist 外はすべて nil（＝同期しない）**にする ——
    /// 知らない項目名を素通しすると `FinderTagSync.sync` が `unsupportedField` を投げるだけで、
    /// ユーザーには「なぜか同期されない」としか見えない。
    static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FinderTagSync.syncableFields.contains(trimmed) else { return nil }
        return trimmed
    }

    static func current(_ database: Database) -> String? {
        // `try?` は `String??` を作るので、必ず 1 段潰してから渡すこと
        // （潰さないと `normalize` が `.some(nil)` を受けて型が合わない）。
        let stored: String? = (try? database.getLibrarySetting(key: key)) ?? nil
        return normalize(stored)
    }

    /// 同期対象の項目を変更する。戻り値は「実際に変わったか」。
    ///
    /// ★ **変わったら前回同期値を全消しする**（spec §4.2）。残したまま切り替えると、
    /// 3 方向マージが**別項目の値を「前回のタグ」と誤認**し、実在しない削除を検出して
    /// ユーザーのタグを大量に消しかねない。
    ///
    /// **消してから設定を書く**。この順なら途中で落ちても「前回値だけ消えた」状態にしかならず、
    /// 次回の同期が初回として安全にやり直す。逆順だと「新しい項目 × 古い前回値」という
    /// 最悪の組み合わせが残る。
    ///
    /// （`FinderTagSync.sync` 自身も同じ保護を持つが、**二重で構わない**。
    /// 片方が抜けたときの被害が非可逆なので、呼び出し側でも必ず消す。）
    @discardableResult
    static func update(_ database: Database, to field: String?) throws -> Bool {
        let new = normalize(field)
        guard current(database) != new else { return false }
        try database.clearAllFinderTagBaselines()
        try database.setLibrarySetting(key: key, value: new ?? "")
        return true
    }
}

// MARK: - ボリュームの根

/// `mdutil -s` / `mdfind -onlyin` に渡すボリュームを、本のパスから求める。
///
/// **`URL.resourceValues(forKeys: [.volumeURLKey])` は使わない。** 12,000 冊分の
/// `stat` を庫を開くたびに走らせることになり、Spotlight 経路の「規模非依存」という
/// 利点（spec §3.2）を自分で捨てることになる。ここは純粋な文字列処理で足りる。
///
/// **`mdutil -s` はボリュームのマウントポイントしか受け付けない**（実測: サブディレクトリを
/// 渡すと `Error: unknown indexing state.`）。だから「本のあるフォルダ」ではなく
/// 「本のあるボリューム」まで遡る必要がある。
enum FinderTagVolumes {
    /// 1 本のパスが属するボリュームの根。判定できなければ nil。
    static func root(forPath path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }   // "/" 自身は本の置き場ではない
        guard first == "Volumes" else { return "/" }        // 起動ボリューム（`/Users/...` を含む）
        guard parts.count >= 2 else { return nil }          // "/Volumes" だけでは行き先が無い
        return "/Volumes/" + parts[1]
    }

    /// 庫の本が跨っているボリュームの根（重複なし・順序は決定的）。
    ///
    /// 普通の庫は 1 個しか返らない。複数返るのは本が複数ボリュームに散っている庫で、
    /// そのときは `FinderTagSyncRunner` がボリュームごとに 1 回ずつ同期を回す。
    static func roots(forPaths paths: [String]) -> [URL] {
        var seen: Set<String> = []
        for path in paths {
            if let root = root(forPath: path) { seen.insert(root) }
        }
        return seen.sorted().map { URL(fileURLWithPath: $0) }
    }
}

// MARK: - 実行結果

/// 1 回の「再照合」の結果（ボリュームを跨いだ合計）。
struct FinderTagSyncOutcome: Sendable, Equatable {
    var updatedInLibrary = 0
    var updatedInFinder = 0
    /// 区切り文字（`", "`）を含むため同期できなかったタグ名（重複なし）。
    var skippedTags: [String] = []
    /// 諦めた本のパス（plist が壊れている / ファイルが無い）。
    var skippedBooks: [String] = []
    /// Spotlight 索引が無効だったボリューム名。**空でないなら Finder → StackNest 方向は動いていない。**
    var indexingDisabledVolumes: [String] = []
    /// 同期そのものが失敗した理由（表示用）。nil なら成功。
    var failure: String?

    var hasChanges: Bool { updatedInLibrary > 0 || updatedInFinder > 0 }
}

/// 「再照合を始められたか、始められなかったならなぜか」。
///
/// **`canStartFinderTagSync`（メニューの有効/無効）とは別物。**あちらは押せるかどうかの
/// 見た目で、こちらは `startFinderTagSync` が実際に何をしたかの事実。両者は食い違いうる ——
/// 庫を開いた後に外部から施錠されると**メニューは有効なのに `.locked` で断られる**
/// （G39 修正波で塞いだ穴が、まさにこの食い違いを見ずに走らせていたもの）。
///
/// 拒否理由を値として返すのは、CLI/MCP からの再照合で「何も起きなかった」と
/// 「施錠されていたので断った」を**呼び出し側が区別できるようにする**ため。
enum FinderTagSyncStart: String, Sendable, Equatable {
    case started
    /// 既に走行中（二重起動の抑止）。
    case alreadyRunning
    /// 庫が開いていない（`database == nil`）。
    case noLibrary
    /// 同期する項目が選ばれていない（既定＝同期しない）。
    case noField
    /// 施錠されている（解錠するまで走らせない）。
    case locked
}

// MARK: - 実行

/// `FinderTagSync.sync` を呼ぶだけの薄い層。**メインスレッドの外で呼ぶこと**（`AppState` の責務）。
enum FinderTagSyncRunner {
    /// 庫の全ボリュームを順に同期して結果を合算する。
    ///
    /// `nonisolated` かつ引数は `Database`（`@unchecked Sendable`）と `String` だけなので、
    /// そのまま `Task.detached` へ渡せる。
    static func run(database: Database, field: String) -> FinderTagSyncOutcome {
        var outcome = FinderTagSyncOutcome()

        let paths: [String]
        do {
            paths = try database.fetchAllBooks().compactMap(\.path)
        } catch {
            outcome.failure = message(for: error)
            return outcome
        }
        let volumes = FinderTagVolumes.roots(forPaths: paths)
        guard !volumes.isEmpty else { return outcome }

        var seenTags: Set<String> = []
        var seenBooks: Set<String> = []
        for volume in volumes {
            // 庫を閉じられた／窓が消えたら、次のボリュームには進まない
            // （同期そのものは同期関数なので途中では止まらない）。
            if Task.isCancelled { break }
            do {
                let report = try FinderTagSync.sync(database: database, volume: volume, field: field)
                outcome.updatedInLibrary += report.updatedInLibrary
                outcome.updatedInFinder += report.updatedInFinder
                for tag in report.skippedTags where seenTags.insert(tag).inserted {
                    outcome.skippedTags.append(tag)
                }
                for book in report.skippedBooks where seenBooks.insert(book).inserted {
                    outcome.skippedBooks.append(book)
                }
                if report.indexingDisabled {
                    outcome.indexingDisabledVolumes.append(volume.lastPathComponent)
                }
            } catch {
                // 1 ボリュームが失敗しても残りは続ける（未マウントのボリュームを 1 つ含む庫でも
                // 他のボリュームは同期されるほうがよい）。最初の理由だけ報告する。
                if outcome.failure == nil { outcome.failure = message(for: error) }
            }
        }
        return outcome
    }

    /// 表示用のエラー文言。`FinderTagSyncError` は `LocalizedError` ではないので
    /// `localizedDescription` に任せると意味の無い文字列になる。
    ///
    /// **この関数の中で `message(for:)` を呼ばないこと**（自己再帰になる。
    /// 過去に同じ形の欠陥を作った実績がある）。
    static func message(for error: Error) -> String {
        switch error {
        case FinderTagSyncError.unsupportedField(let field):
            return String(localized: "「\(field)」は Finder タグと同期できない項目です。")
        case FinderTagSyncError.volumeUnavailable(let path):
            return String(localized: "ボリューム「\(path)」が見つかりません（未マウント？）。")
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - ユーザーへの提示

/// 同期を起こしたきっかけ。**表示のうるささを変えるためだけに持つ**
/// （庫を開くたびに「変更なし」と出るのは邪魔だが、手動で押したのに無反応なのは不安）。
enum FinderTagSyncTrigger: Equatable {
    case libraryOpened
    case manual
}

/// 同期結果のバナー 1 枚分。
struct FinderTagSyncNotice: Equatable {
    enum Kind: Equatable { case info, warning }

    var kind: Kind
    var text: String
    /// 「詳細」で開くアラートの本文（スキップしたタグ名・本のパスの一覧）。
    var detail: String?

    /// 報告するに値するか（値しないなら nil）を含めて文言を組む。
    ///
    /// - **黙って同期されないのが最悪**なので、索引無効・スキップは必ず出す（`.warning`）。
    /// - 変化も警告も無いときは、庫を開いた契機なら**出さない**。手動なら「変更なし」と出す。
    static func make(outcome: FinderTagSyncOutcome,
                     trigger: FinderTagSyncTrigger,
                     fieldLabel: String) -> FinderTagSyncNotice? {
        var lines: [String] = []
        var details: [String] = []

        if let failure = outcome.failure {
            lines.append(String(localized: "Finder タグを同期できませんでした: \(failure)"))
        }
        if !outcome.indexingDisabledVolumes.isEmpty {
            let names = outcome.indexingDisabledVolumes.joined(separator: "・")
            lines.append(String(localized: "「\(names)」は Spotlight 索引が無効です。Finder で付けたタグは取り込めません（\(fieldLabel) → Finder の書き戻しのみ動作）。"))
        }
        if !outcome.skippedTags.isEmpty {
            lines.append(String(localized: "「, 」を含むタグ \(outcome.skippedTags.count) 件は同期していません。"))
            details.append(String(localized: "同期できなかったタグ:") + "\n"
                           + outcome.skippedTags.map { "  ・\($0)" }.joined(separator: "\n"))
        }
        if !outcome.skippedBooks.isEmpty {
            lines.append(String(localized: "\(outcome.skippedBooks.count) 冊はタグを読めませんでした。"))
            details.append(String(localized: "タグを読めなかった本:") + "\n"
                           + outcome.skippedBooks.prefix(50).map { "  ・\($0)" }.joined(separator: "\n")
                           + (outcome.skippedBooks.count > 50 ? "\n  …" : ""))
        }

        let isWarning = !lines.isEmpty
        if outcome.hasChanges {
            var parts: [String] = []
            if outcome.updatedInLibrary > 0 {
                parts.append(String(localized: "Finder → \(fieldLabel) \(outcome.updatedInLibrary) 件"))
            }
            if outcome.updatedInFinder > 0 {
                parts.append(String(localized: "\(fieldLabel) → Finder \(outcome.updatedInFinder) 件"))
            }
            lines.insert(String(localized: "Finder タグを同期しました（\(parts.joined(separator: " / "))）"), at: 0)
        } else if !isWarning {
            guard trigger == .manual else { return nil }
            lines.append(String(localized: "Finder タグ: 変更はありませんでした"))
        }

        return FinderTagSyncNotice(kind: isWarning ? .warning : .info,
                                   text: lines.joined(separator: " "),
                                   detail: details.isEmpty ? nil : details.joined(separator: "\n\n"))
    }
}

// MARK: - バナー

/// `LibraryBrowserView` の上端に出す通知バナー。
///
/// **警告は自動で消さない**（`AppState` 側で消去タイマを張らない）。索引無効やスキップは
/// 「5 秒見逃したら二度と分からない」種類の情報で、それでは黙って同期されないのと大差ない。
struct FinderTagSyncBanner: View {
    let notice: FinderTagSyncNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.kind == .warning ? "exclamationmark.triangle.fill" : "tag")
                .foregroundStyle(notice.kind == .warning ? Color.orange : Color.secondary)
            Text(notice.text)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: 520, alignment: .leading)
            if notice.detail != nil {
                Button("詳細") { showDetail() }
                    .buttonStyle(.link)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("この通知を閉じる")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.secondary.opacity(0.3)))
        .shadow(radius: 4)
    }

    private func showDetail() {
        let alert = NSAlert()
        alert.messageText = notice.text
        alert.informativeText = notice.detail ?? ""
        alert.runModal()
    }
}
