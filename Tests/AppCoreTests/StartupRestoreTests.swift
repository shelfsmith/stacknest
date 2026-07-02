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
}
