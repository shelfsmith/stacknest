// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
@testable import StackNest

/// 監視フォルダの取り込み結果 → 文言。
///
/// ★ **今までこの経路は「N 件失敗」としか言わず、どのファイルがなぜ失敗したかを
/// 知る手段がゼロだった**（`ImportResult.failed` は URL とエラーを持っているのに捨てていた）。
///
/// `cancelled` の分岐もここで固定するが、**現状この枝には実際には届かない**
/// （理由は `WatchImportNotice` のコメントを参照。中断した回の結果は世代ガードが捨てる）。
/// 分岐そのものは正しく妥当な防御なので、テストごと残す。
@Suite("取り込み結果のお知らせ（G41）")
struct WatchImportNoticeTests {

    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "壊れています" }
    }

    private func result(added: Int = 0,
                        failed: [(URL, any Error)] = [],
                        coverFailures: [URL] = [],
                        cancelled: Bool = false) -> BookImporter.ImportResult {
        var r = BookImporter.ImportResult()
        r.addedIDs = Array(1...max(added, 1)).prefix(added).map { $0 }
        r.failed = failed
        r.coverFailures = coverFailures
        r.cancelled = cancelled
        return r
    }

    @Test("何も起きていなければ出さない")
    func silentWhenNothingHappened() {
        #expect(WatchImportNotice.make(result()) == nil)
    }

    @Test("追加だけなら info")
    func additionsAreInfo() throws {
        let n = try #require(WatchImportNotice.make(result(added: 3)))
        #expect(n.kind == .info)
        #expect(n.text.contains("3 件を自動追加"))
        #expect(n.detail == nil)
    }

    /// ★ 本命: 失敗は**消えない警告**にし、**どのファイルがなぜ失敗したか**を詳細に入れる。
    @Test("失敗があれば warning で、詳細にパスと理由が入る")
    func failuresAreWarningsWithDetail() throws {
        let bad = URL(fileURLWithPath: "/tmp/壊れ.cbz")
        let n = try #require(WatchImportNotice.make(
            result(added: 3, failed: [(bad, Boom())])))
        #expect(n.kind == .warning)
        #expect(n.text.contains("3 件を自動追加"))
        #expect(n.text.contains("1 件失敗"))
        let detail = try #require(n.detail)
        #expect(detail.contains("/tmp/壊れ.cbz"))
        #expect(detail.contains("壊れています"), "理由が入っていない: \(detail)")
    }

    @Test("表紙を作れなかった分も warning で、詳細にパスが入る")
    func coverFailuresAreWarningsWithDetail() throws {
        let noCover = URL(fileURLWithPath: "/tmp/中身なし.zip")
        let n = try #require(WatchImportNotice.make(
            result(added: 1, coverFailures: [noCover])))
        #expect(n.kind == .warning)
        #expect(n.text.contains("表紙なし 1 件"))
        #expect(try #require(n.detail).contains("/tmp/中身なし.zip"))
    }

    /// G36 が足した印。**現状は世代ガードに守られて実際には届かない枝**だが、
    /// `WatchImportNotice.make` の判定自体は正しいので固定しておく
    /// （詳細は `WatchImportNotice` のコメント）。
    @Test("中断したら warning で、そうと分かる")
    func cancellationIsReported() throws {
        let n = try #require(WatchImportNotice.make(result(added: 2, cancelled: true)))
        #expect(n.kind == .warning)
        #expect(n.text.contains("中断"))
        #expect(n.text.contains("2 件を自動追加"))
    }

    /// 追加が 0 件でも、中断したなら黙らない。
    @Test("中断だけでも出す")
    func cancellationAloneIsStillReported() throws {
        let n = try #require(WatchImportNotice.make(result(cancelled: true)))
        #expect(n.kind == .warning)
        #expect(n.text.contains("中断"))
    }

    /// 長い一覧でバナーの詳細が膨らまないよう 50 件で打ち切る（G39 と同じ方針）。
    @Test("詳細は 50 件で打ち切る")
    func detailIsTruncatedAtFifty() throws {
        let many = (0..<60).map { (URL(fileURLWithPath: "/tmp/f\($0).cbz"), Boom() as any Error) }
        let n = try #require(WatchImportNotice.make(result(failed: many)))
        let detail = try #require(n.detail)
        #expect(detail.contains("/tmp/f49.cbz"))
        #expect(detail.contains("/tmp/f50.cbz") == false, "51 件目まで出ている")
        #expect(detail.contains("…"))
    }

    /// 監視フォルダは同じファイルを何度も見るので、既にある分は**出さない**（ノイズになる）。
    @Test("既にある分は報告しない")
    func alreadyPresentIsNotReported() {
        var r = BookImporter.ImportResult()
        r.alreadyPresent = [URL(fileURLWithPath: "/tmp/ある.cbz")]
        #expect(WatchImportNotice.make(r) == nil)
    }
}

/// Codex レビュー P2（2026-08-26）: **未読の警告を「ついで」の成功報告で消さない。**
///
/// 監視フォルダは繰り返し走る。失敗の警告が次の成功報告（info）に置き換えられ、
/// その 6 秒後には何も残らない —— 「警告は自動で消さない」という約束が黙って破れ、
/// **どのファイルが失敗したかを見る機会が永久に失われる**。
///
/// ★ この規則は **`NoticeSlot` ではなく producer 側**にある。Finder タグ同期の枠では
/// 警告のあとの info は「警告の条件が消えた」ことを意味するので、そちらは置き換わるのが正しい。
@Suite("警告を成功報告で消さない（G41・Codex P2）")
struct WatchImportNoticeReplacementTests {
    private func info(_ t: String = "3 件を自動追加") -> Notice { Notice(kind: .info, text: t, detail: nil) }
    private func warn(_ t: String = "2 件失敗") -> Notice { Notice(kind: .warning, text: t, detail: "…") }

    /// ★ 本命。ここが false でないと、失敗の報告が次の成功で流れる。
    @Test("警告が出ているとき、info では置き換えない")
    func infoDoesNotDisplaceAWarning() {
        #expect(WatchImportNotice.shouldReplace(current: warn(), with: info()) == false)
    }

    @Test("警告は新しい警告で置き換える")
    func warningReplacesWarning() {
        #expect(WatchImportNotice.shouldReplace(current: warn("古い"), with: warn("新しい")))
    }

    @Test("info は info で置き換える")
    func infoReplacesInfo() {
        #expect(WatchImportNotice.shouldReplace(current: info("先"), with: info("後")))
    }

    @Test("何も出ていなければ何でも出す")
    func anythingShowsOnAnEmptySlot() {
        #expect(WatchImportNotice.shouldReplace(current: nil, with: info()))
        #expect(WatchImportNotice.shouldReplace(current: nil, with: warn()))
    }

    /// 警告のあとに警告が来たら、**新しい方の内容**が見えること（古いのが居座らない）。
    @Test("新しい失敗の内容が見える")
    func theNewerFailureIsWhatYouSee() {
        #expect(WatchImportNotice.shouldReplace(current: warn("1 件失敗"), with: warn("5 件失敗")))
    }
}
