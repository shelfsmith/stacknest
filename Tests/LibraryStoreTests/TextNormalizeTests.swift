// SPDX-License-Identifier: MIT
import Testing
@testable import LibraryStore

@Suite("TextNormalize")
struct TextNormalizeTests {
    @Test func decomposedBecomesPrecomposed() {
        // フ (U+30D5) + combining dakuten (U+3099) = NFD "ブ" — 2 scalars, 6 UTF-8 bytes.
        // Swift String == uses canonical equivalence, so we use UTF-8 byte counts to distinguish.
        let nfd = "\u{30D5}\u{3099}"   // decomposed ブ — 2 unicode scalars
        let nfc = "\u{30D6}"           // precomposed ブ — 1 unicode scalar
        // Confirm the two literals are byte-distinct before normalization.
        #expect(Array(nfd.utf8) != Array(nfc.utf8))
        // After normalization, the bytes should match the precomposed form.
        let normalized = TextNormalize.nfc(nfd)
        #expect(Array(normalized.utf8) == Array(nfc.utf8))
        // Idempotent: already-NFC input is unchanged.
        #expect(Array(TextNormalize.nfc(nfc).utf8) == Array(nfc.utf8))
        // Optional overload: nil passes through as nil.
        #expect(TextNormalize.nfc(String?.none) == nil)
    }
}
