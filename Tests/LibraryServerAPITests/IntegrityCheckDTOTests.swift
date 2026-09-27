// SPDX-License-Identifier: MIT
import Testing
@testable import LibraryServerAPI

@Suite("G56-S1: 破損チェックの失敗の行は言語に依らない")
struct IntegrityCheckDTOTests {
    @Test func errorRowIsStableASCII() {
        #expect(IntegrityCheckDTO.errorRow == "(error)")
        #expect(IntegrityCheckDTO.errorRow.unicodeScalars.allSatisfy { $0.isASCII })
    }
}
