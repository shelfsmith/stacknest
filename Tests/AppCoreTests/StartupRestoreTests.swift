// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("StartupRestore")
struct StartupRestoreTests {
    private func u(_ s: String) -> URL { URL(fileURLWithPath: "/lib/\(s).stacknest") }

    @Test func nilOpenSetFallsBackToRecency() {
        let a = u("A")
        let r = StartupRestore.librariesToRestore(openSet: nil, recencyFirst: a, exists: { _ in true })
        #expect(r == [a])
    }
    @Test func nilOpenSetRecencyMissing() {
        let a = u("A")
        let r = StartupRestore.librariesToRestore(openSet: nil, recencyFirst: a, exists: { _ in false })
        #expect(r.isEmpty)
    }
    @Test func nilOpenSetNoRecency() {
        let r = StartupRestore.librariesToRestore(openSet: nil, recencyFirst: nil, exists: { _ in true })
        #expect(r.isEmpty)
    }
    @Test func emptyOpenSet() {
        let r = StartupRestore.librariesToRestore(openSet: [], recencyFirst: u("A"), exists: { _ in true })
        #expect(r.isEmpty)
    }
    @Test func nonEmptyFiltersAndOrdersRecencyLast() {
        let a = u("A"); let b = u("B"); let c = u("C")
        let r = StartupRestore.librariesToRestore(
            openSet: [a, b, c], recencyFirst: b,
            exists: { $0 != c })
        #expect(r == [a, b])
    }
    @Test func recencyNotInSet() {
        let a = u("A"); let b = u("B")
        let r = StartupRestore.librariesToRestore(openSet: [a, b], recencyFirst: u("Z"), exists: { _ in true })
        #expect(r == [a, b])
    }
    // openSet 非空だが全部不存在 → 空（spec 5.1 ⑤）
    @Test func nonEmptyAllMissing() {
        let a = u("A"); let b = u("B")
        let r = StartupRestore.librariesToRestore(openSet: [a, b], recencyFirst: a, exists: { _ in false })
        #expect(r.isEmpty)
    }

    // MARK: - plan（failedToRestore＝アラート要否）

    // 意図的に空（open-set=[]）→ urls 空・failed=false（誤アラートを出さない・品質レビュー I-1）
    @Test func planEmptyOpenSetNoAlert() {
        let p = StartupRestore.plan(openSet: [], recencyFirst: u("A"), exists: { _ in true })
        #expect(p.urls.isEmpty)
        #expect(p.failedToRestore == false)
    }
    // 前回開いていたのに全滅 → failed=true
    @Test func planNonEmptyAllMissingFails() {
        let a = u("A"); let b = u("B")
        let p = StartupRestore.plan(openSet: [a, b], recencyFirst: a, exists: { _ in false })
        #expect(p.urls.isEmpty)
        #expect(p.failedToRestore)
    }
    // 未書込＋recency 不存在 → failed=true（従来の単一復元が失敗）
    @Test func planNilRecencyMissingFails() {
        let p = StartupRestore.plan(openSet: nil, recencyFirst: u("A"), exists: { _ in false })
        #expect(p.urls.isEmpty)
        #expect(p.failedToRestore)
    }
    // 未書込＋recency なし → failed=false（開く意図が無い）
    @Test func planNilNoRecencyNoAlert() {
        let p = StartupRestore.plan(openSet: nil, recencyFirst: nil, exists: { _ in true })
        #expect(p.urls.isEmpty)
        #expect(p.failedToRestore == false)
    }
    // 復元成功 → failed=false
    @Test func planRestoresNoAlert() {
        let a = u("A"); let b = u("B")
        let p = StartupRestore.plan(openSet: [a, b], recencyFirst: b, exists: { _ in true })
        #expect(p.urls == [a, b])
        #expect(p.failedToRestore == false)
    }
}
