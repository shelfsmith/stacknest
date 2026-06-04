// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("StampField")
struct StampFieldTests {
    @Test
    func allCasesIs5() throws {
        #expect(StampField.allCases.count == 5)
    }

    @Test
    func dbColumnMapping() throws {
        #expect(StampField.genre.dbColumn == "genre")
        #expect(StampField.neta.dbColumn == "neta")
        #expect(StampField.keywordA.dbColumn == "keyword_a")
        #expect(StampField.keywordB.dbColumn == "keyword_b")
        #expect(StampField.keywordC.dbColumn == "keyword_c")
    }

    @Test
    func localizedTitleNonEmpty() throws {
        for f in StampField.allCases {
            #expect(!f.localizedTitle.isEmpty)
        }
    }
}
