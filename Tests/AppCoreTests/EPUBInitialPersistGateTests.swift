// SPDX-License-Identifier: MIT
import Testing
import Foundation
import EPUBAdapter
@testable import AppCore

/// G54-S3e（spec §2.1-8・平木氏の判断）: ダウンロード済みの次の巻をサーバの情報（manifest）なしで開いたとき、
/// 開いた直後に報告される先頭の位置をサーバへ送ると、サーバ側の読書位置を先頭で上書きしてしまう。
/// **最初に報告された位置と違う位置が来るまで**保存しない。
@Suite("G54-S3e: 利用者が動くまで保存しない門")
struct EPUBInitialPersistGateTests {
    private func loc(_ spine: Int, _ progress: Double, cfi: String? = nil) -> EPUBLocatorValue {
        EPUBLocatorValue(spine: spine, progress: progress, cfi: cfi, engine: cfi == nil ? nil : "washi")
    }

    @Test func notHeldAlwaysAllows() {
        var gate = EPUBInitialPersistGate(holdUntilMoved: false)
        #expect(gate.allowsPersist)
        gate.observe(loc(0, 0))
        #expect(gate.allowsPersist)
    }

    @Test func heldBlocksUntilTheFirstReport() {
        let gate = EPUBInitialPersistGate(holdUntilMoved: true)
        #expect(!gate.allowsPersist)
    }

    @Test func heldBlocksTheFirstReportAndItsRepeats() {
        var gate = EPUBInitialPersistGate(holdUntilMoved: true)
        gate.observe(loc(0, 0))
        #expect(!gate.allowsPersist)
        gate.observe(loc(0, 0))
        #expect(!gate.allowsPersist)
    }

    /// Review Focus 1: 全画面化・リサイズの組み直しで、同じ場所が cfi だけ変えて報告し直されても開かない。
    @Test func sameSpotWithADifferentCFIKeepsHolding() {
        var gate = EPUBInitialPersistGate(holdUntilMoved: true)
        gate.observe(loc(0, 0))
        gate.observe(loc(0, 0, cfi: "epubcfi(/6/2!/4/2)"))
        #expect(!gate.allowsPersist)
    }

    @Test func movingOpensItForGood() {
        var gate = EPUBInitialPersistGate(holdUntilMoved: true)
        gate.observe(loc(0, 0))
        gate.observe(loc(0, 0.1))
        #expect(gate.allowsPersist)
        gate.observe(loc(0, 0))      // 先頭へ戻っても、もう利用者の読書なので止めない
        #expect(gate.allowsPersist)
    }

    @Test func movingToAnotherSpineOpensIt() {
        var gate = EPUBInitialPersistGate(holdUntilMoved: true)
        gate.observe(loc(0, 0))
        gate.observe(loc(1, 0))
        #expect(gate.allowsPersist)
    }
}
