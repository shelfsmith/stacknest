// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G26 最終レビュー Important #1 の回帰テスト。
/// 「破損（打ち切り）読みから導いた数値は記録しない」を判定表として固定する。
struct TruncatedReadPolicyTests {

    // MARK: - pages（books.pages）

    /// 正常読みならライブのページ数をそのまま書く（＝修復後に正しい値へ収束する経路）。
    @Test func intactReadWritesLivePageCount() {
        #expect(TruncatedReadPolicy.pageCountToWrite(livePageCount: 150, truncated: false) == 150)
    }

    /// 打ち切り読みでは pages を書かない。書くと「30/30＝読了」に化ける。
    @Test func truncatedReadWritesNoPageCount() {
        #expect(TruncatedReadPolicy.pageCountToWrite(livePageCount: 30, truncated: true) == nil)
    }

    /// 0 ページは収束材料にならないので、正常読み扱いでも書かない。
    @Test func zeroPageCountIsNeverWritten() {
        #expect(TruncatedReadPolicy.pageCountToWrite(livePageCount: 0, truncated: false) == nil)
        #expect(TruncatedReadPolicy.pageCountToWrite(livePageCount: -1, truncated: false) == nil)
    }

    // MARK: - last_page（book_viewer_state）

    /// 本丸の再現ケース: 150 ページ読んだ本が 30 ページまでしか読めなくなると、
    /// `ViewerModel.goTo(page:)` が 149 → 29 にクランプする。その 29 を書き戻してはいけない。
    @Test func clampedPositionOfDamagedBookIsNotRecorded() {
        // 保存済み 149（0-based）、破損で 30 ページまでしか開けず 29 にクランプされた状態。
        let page = TruncatedReadPolicy.lastPageToPersist(
            currentPage: 29, storedLastPage: 149, truncated: true)
        #expect(page == 149)   // 保存値をそのまま書き直す＝読書位置は失われない
    }

    /// 破損していなければ、位置が戻っていてもユーザー操作なのでそのまま記録する。
    @Test func intactBookRecordsBackwardNavigation() {
        let page = TruncatedReadPolicy.lastPageToPersist(
            currentPage: 29, storedLastPage: 149, truncated: false)
        #expect(page == 29)
    }

    /// 破損本でも前進はクランプでは起こらない（クランプは下げるだけ）ので記録する。
    @Test func damagedBookRecordsForwardProgress() {
        #expect(TruncatedReadPolicy.lastPageToPersist(
            currentPage: 20, storedLastPage: 5, truncated: true) == 20)
        // 同値（動いていない）も「下がっていない」ので書いてよい。
        #expect(TruncatedReadPolicy.lastPageToPersist(
            currentPage: 5, storedLastPage: 5, truncated: true) == 5)
    }

    /// 未読（保存値 0）の破損本は下限が 0 なので常に現在位置を記録する。
    /// 「最初から」を選んだ場合も呼び出し側が storedLastPage を 0 に落とすため、この経路になる。
    @Test func unreadDamagedBookRecordsCurrentPage() {
        #expect(TruncatedReadPolicy.lastPageToPersist(
            currentPage: 0, storedLastPage: 0, truncated: true) == 0)
        #expect(TruncatedReadPolicy.lastPageToPersist(
            currentPage: 12, storedLastPage: 0, truncated: true) == 12)
    }

    // MARK: - truncationAffectsLastPage（G26 Codex Important #1）

    /// この述語の**唯一の存在理由**は「false なら破損判定を省いてよい」という保証なので、
    /// その不変条件を総当りで固定する。ここが崩れると、サーバ `/progress` が
    /// 「前進だから damageNote を見なくてよい」と判断した書き込みが実は保護対象だった、
    /// という取りこぼしになる（しかも静かに壊れる）。
    @Test func skippingTheTruncationCheckNeverChangesTheAnswer() {
        for current in -1...6 {
            for stored in 0...6 {
                let withTruncation = TruncatedReadPolicy.lastPageToPersist(
                    currentPage: current, storedLastPage: stored, truncated: true)
                let without = TruncatedReadPolicy.lastPageToPersist(
                    currentPage: current, storedLastPage: stored, truncated: false)
                if TruncatedReadPolicy.truncationAffectsLastPage(
                    currentPage: current, storedLastPage: stored) {
                    continue   // 差が出てよい領域（実際に差が出るかは上の個別テストが見る）
                }
                #expect(withTruncation == without,
                        "truncationAffectsLastPage が false なのに答えが変わる (current=\(current), stored=\(stored))")
            }
        }
    }

    /// 後退（＝クランプの疑いがある）ときだけ破損判定が要る。
    @Test func onlyBackwardWritesNeedTheTruncationCheck() {
        #expect(TruncatedReadPolicy.truncationAffectsLastPage(currentPage: 29, storedLastPage: 149))
        #expect(!TruncatedReadPolicy.truncationAffectsLastPage(currentPage: 149, storedLastPage: 149))
        #expect(!TruncatedReadPolicy.truncationAffectsLastPage(currentPage: 150, storedLastPage: 149))
        #expect(!TruncatedReadPolicy.truncationAffectsLastPage(currentPage: 0, storedLastPage: 0))
    }

    // MARK: - pageCountForClassification（G26 Codex Minor #2）

    /// 打ち切り読みのページ数は bookType 自動分類にも渡さない。
    /// bookType は永続化され、しかも修復後に見直されない（pages と違って収束経路が無い）。
    @Test func truncatedPageCountIsNotOfferedToClassification() {
        #expect(TruncatedReadPolicy.pageCountForClassification(livePageCount: 13, truncated: true) == nil)
    }

    /// 正常読みならそのまま渡す。0 ページも**分類では**正しい入力なので素通しする
    /// （`pageCountToWrite` が 0 を弾くのは「pages を収束させる材料が無い」という別の理由）。
    @Test func intactPageCountIsOfferedToClassificationIncludingZero() {
        #expect(TruncatedReadPolicy.pageCountForClassification(livePageCount: 13, truncated: false) == 13)
        #expect(TruncatedReadPolicy.pageCountForClassification(livePageCount: 0, truncated: false) == 0)
    }
}
