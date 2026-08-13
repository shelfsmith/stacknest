// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G35a-1 Task A2: `WatchScanPlanner`。
///
/// `FolderWatcher.scanAll()` のうち **MainActor を必要としない判定部分**を切り出したもの。
/// 元は `@MainActor` の App ターゲットにあり **テストが 1 本も無かった** ―― 切り出しは
/// メインスレッドを空けるためだけでなく、テスト可能性の獲得でもある
/// （`ResumeGate` / `CoverRegen` / `FullIntegrityScanner.Dependencies` と同じ流儀）。
///
/// **これは移設であって仕様変更ではない。** 既存の `WatchFolderScanner` の判定
/// （`importable` / `decideStable` / `filterRetry`）はそのまま使う。
@Suite("WatchScanPlanner（監視フォルダ走査の判定・G35a-1）")
struct WatchScanPlannerTests {

    private func folder(_ path: String, baseline: [String] = [],
                        mode: WatchedFolder.SubfolderMode = .topLevelOnly) -> WatchedFolder {
        WatchedFolder(id: UUID().uuidString, path: path, enabled: true,
                      presetID: nil, baseline: baseline, subfolderMode: mode)
    }

    /// 実ファイル無しで全分岐を通すための注入 I/O。
    private func io(existing: Set<String> = [],
                    entries: [String: [String]] = [:],      // フォルダ path → 直下 URL path
                    sizes: [String: Int64] = [:]) -> WatchScanPlanner.IO {
        WatchScanPlanner.IO(
            existingPaths: { existing },
            enumerate: { url, _ in (entries[url.path] ?? []).map { URL(fileURLWithPath: $0) } },
            totalSize: { sizes[$0.path] ?? 0 })
    }

    // MARK: - 1. サイズ安定化（2 回連続で同一サイズなら取り込み対象）

    @Test("1 回目は pending、2 回目でサイズ不変なら attemptable になる")
    func stabilisesOverTwoScans() {
        let f = folder("/watch")
        let deps = io(entries: ["/watch": ["/watch/a.zip"]], sizes: ["/watch/a.zip": 100])

        let first = WatchScanPlanner.plan(folders: [f], lastSizes: [:], rejectedSizes: [:], io: deps)
        #expect(first.attemptable.isEmpty)
        #expect(first.pending == ["/watch/a.zip": 100])
        #expect(first.hasPending)

        let second = WatchScanPlanner.plan(folders: [f], lastSizes: first.pending,
                                           rejectedSizes: [:], io: deps)
        #expect(second.attemptable == ["/watch/a.zip"])
        #expect(second.hasPending == false)
    }

    /// ★ サイズが増えている間は取り込まない（コピー中のファイルを掴まない）。
    @Test("サイズが変わっている間は attemptable にならない")
    func growingFileStaysPending() {
        let f = folder("/watch")
        let first = WatchScanPlanner.plan(
            folders: [f], lastSizes: ["/watch/a.zip": 100], rejectedSizes: [:],
            io: io(entries: ["/watch": ["/watch/a.zip"]], sizes: ["/watch/a.zip": 250]))

        #expect(first.attemptable.isEmpty)
        #expect(first.pending == ["/watch/a.zip": 250])
    }

    // MARK: - 2. サイズ 0 は記録しない（既存の意図）

    /// 空フォルダや 0 バイトファイルは 0==0 で「安定」と誤判定され、中身が入る前に
    /// 取り込まれてしまう。一度取り込むと既存パスになり二度と再取込されない事故になるため、
    /// **そもそも currentSizes に載せない**（既存 `scanAll` のコメント参照）。
    @Test("サイズ 0 の候補は記録も対象にもしない")
    func zeroSizedCandidatesAreIgnored() {
        let f = folder("/watch")
        let plan = WatchScanPlanner.plan(
            folders: [f], lastSizes: [:], rejectedSizes: [:],
            io: io(entries: ["/watch": ["/watch/empty", "/watch/a.zip"]],
                   sizes: ["/watch/empty": 0, "/watch/a.zip": 10]))

        #expect(plan.currentSizes["/watch/empty"] == nil)
        #expect(plan.candidatesByPath["/watch/empty"] == nil)
        #expect(plan.currentSizes["/watch/a.zip"] == 10)
    }

    // MARK: - 3. 既存パス・ベースラインの除外

    @Test("ライブラリに既にあるパスは候補にならない")
    func existingLibraryPathsAreExcluded() {
        let f = folder("/watch")
        let plan = WatchScanPlanner.plan(
            folders: [f], lastSizes: [:], rejectedSizes: [:],
            io: io(existing: ["/watch/known.zip"],
                   entries: ["/watch": ["/watch/known.zip", "/watch/new.zip"]],
                   sizes: ["/watch/known.zip": 10, "/watch/new.zip": 20]))

        #expect(plan.currentSizes["/watch/known.zip"] == nil)
        #expect(plan.currentSizes["/watch/new.zip"] == 20)
    }

    @Test("baseline のパスは候補にならない")
    func baselinePathsAreExcluded() {
        let f = folder("/watch", baseline: ["/watch/skipme.zip"])
        let plan = WatchScanPlanner.plan(
            folders: [f], lastSizes: [:], rejectedSizes: [:],
            io: io(entries: ["/watch": ["/watch/skipme.zip", "/watch/new.zip"]],
                   sizes: ["/watch/skipme.zip": 10, "/watch/new.zip": 20]))

        #expect(plan.currentSizes["/watch/skipme.zip"] == nil)
        #expect(plan.currentSizes["/watch/new.zip"] == 20)
    }

    // MARK: - 4. 拒否済み候補の再試行抑止

    /// フォルダゲートに弾かれた候補を、サイズが変わらないまま 60 秒ごとに再試行すると
    /// 「1 件失敗」バナーが永久に出続ける（既存 `filterRetry` が防いでいる挙動）。
    @Test("拒否時と同じサイズなら attemptable から外れる")
    func rejectedCandidateWithSameSizeIsSkipped() {
        let f = folder("/watch")
        let deps = io(entries: ["/watch": ["/watch/notes"]], sizes: ["/watch/notes": 500])

        let plan = WatchScanPlanner.plan(
            folders: [f], lastSizes: ["/watch/notes": 500],
            rejectedSizes: ["/watch/notes": 500], io: deps)

        #expect(plan.attemptable.isEmpty)
        // ただし currentSizes には載る（次回サイズ比較のため）
        #expect(plan.currentSizes["/watch/notes"] == 500)
    }

    @Test("拒否時とサイズが違えば attemptable に戻る")
    func rejectedCandidateReturnsWhenSizeChanges() {
        let f = folder("/watch")
        let plan = WatchScanPlanner.plan(
            folders: [f], lastSizes: ["/watch/notes": 900],
            rejectedSizes: ["/watch/notes": 500],
            io: io(entries: ["/watch": ["/watch/notes"]], sizes: ["/watch/notes": 900]))

        #expect(plan.attemptable == ["/watch/notes"])
    }

    // MARK: - 5. 複数フォルダ

    @Test("複数の監視フォルダをまたいで集計する")
    func aggregatesAcrossFolders() {
        let a = folder("/watchA")
        let b = folder("/watchB")
        let deps = io(entries: ["/watchA": ["/watchA/1.zip"], "/watchB": ["/watchB/2.zip"]],
                      sizes: ["/watchA/1.zip": 10, "/watchB/2.zip": 20])

        let first = WatchScanPlanner.plan(folders: [a, b], lastSizes: [:], rejectedSizes: [:], io: deps)
        let second = WatchScanPlanner.plan(folders: [a, b], lastSizes: first.pending,
                                           rejectedSizes: [:], io: deps)

        #expect(second.attemptable == ["/watchA/1.zip", "/watchB/2.zip"])
        #expect(second.candidatesByPath["/watchA/1.zip"]?.folder.path == "/watchA")
        #expect(second.candidatesByPath["/watchB/2.zip"]?.folder.path == "/watchB")
    }

    /// 候補と「どの監視フォルダ由来か」の対応が失われると、取り込み時のプリセット
    /// （ファイル名フォーマット）が別フォルダのものになる。
    @Test("候補はどのフォルダ由来かを保持する")
    func candidateKeepsItsFolder() {
        let f = folder("/watch", mode: .archive)
        let deps = io(entries: ["/watch": ["/watch/book"]], sizes: ["/watch/book": 42])
        let plan = WatchScanPlanner.plan(folders: [f], lastSizes: ["/watch/book": 42],
                                         rejectedSizes: [:], io: deps)

        let c = plan.candidatesByPath["/watch/book"]
        #expect(c?.url.path == "/watch/book")
        #expect(c?.folder.id == f.id)
        #expect(c?.folder.subfolderMode == .archive)
    }

    // MARK: - 6. 何も無いとき

    @Test("候補が無ければ空の計画を返す")
    func emptyWhenNothingToDo() {
        let plan = WatchScanPlanner.plan(folders: [folder("/watch")], lastSizes: [:],
                                         rejectedSizes: [:], io: io())
        #expect(plan.attemptable.isEmpty)
        #expect(plan.currentSizes.isEmpty)
        #expect(plan.hasPending == false)
    }

    @Test("監視フォルダが 1 つも無ければ何も見ない")
    func noFolders() {
        let plan = WatchScanPlanner.plan(folders: [], lastSizes: [:], rejectedSizes: [:],
                                         io: io(entries: ["/watch": ["/watch/a.zip"]],
                                                sizes: ["/watch/a.zip": 10]))
        #expect(plan.currentSizes.isEmpty)
    }
}
