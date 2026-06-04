// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackroomFormat

@Suite("BookAnomaly + dict-key validation")
struct BookAnomalyValidationTests {
    @Test("validateDictKey returns Int when valid")
    func validatesIntegerKey() throws {
        let result = try LibraryDocument.validateDictKey("42")
        #expect(result == 42)
    }

    @Test("validateDictKey throws BookAnomaly.dictKeyNotInteger when invalid")
    func throwsOnInvalidKey() {
        #expect(throws: BookAnomaly.dictKeyNotInteger(rawKey: "abc")) {
            _ = try LibraryDocument.validateDictKey("abc")
        }
    }

    @Test("BookAnomaly conforms to LocalizedError with informative message")
    func bookAnomalyHasMessage() {
        let a = BookAnomaly.dictKeyNotInteger(rawKey: "abc")
        let desc = a.localizedDescription
        #expect(desc.contains("integer"))
        #expect(desc.contains("abc"))
    }

    @Test("All BookAnomaly cases have descriptions")
    func allCasesHaveDescriptions() {
        let cases: [BookAnomaly] = [
            .dictKeyNotInteger(rawKey: ""),
            .missingRequiredField(name: "Title"),
            .malformedDate(field: "Date Added"),
            .dateOutOfRange(field: "Date Added", value: Date(timeIntervalSince1970: 0)),
            .malformedBookEntry(rawKey: "X", underlying: "typeMismatch"),
        ]
        for c in cases {
            #expect(c.errorDescription != nil)
            #expect(c.errorDescription!.count > 0)
        }
    }

    @Test("LibraryDocument.init(from:) recovers from a malformed Books entry")
    func decoderRecoversFromMalformedEntry() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Books</key>
            <dict>
                <key>1</key>
                <dict>
                    <key>ID</key><integer>1</integer>
                    <key>Title</key><string>Good</string>
                    <key>Genre</key><string>g</string>
                    <key>Cover Image Path</key><string>/c</string>
                    <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
                    <key>Book Type</key><integer>0</integer>
                    <key>File Type</key><integer>2</integer>
                    <key>My Rate</key><integer>0</integer>
                </dict>
                <key>BadEntry</key>
                <integer>999</integer>
            </dict>
            <key>Playlists</key>
            <array/>
        </dict>
        </plist>
        """
        let doc = try PropertyListDecoder().decode(LibraryDocument.self, from: Data(xml.utf8))
        #expect(doc.books.count == 1)
        #expect(doc.books["1"]?.title == "Good")
        #expect(doc.anomalies.count == 1)
        if case .malformedBookEntry(let raw, _) = doc.anomalies[0] {
            #expect(raw == "BadEntry")
        } else {
            Issue.record("Expected .malformedBookEntry, got \(doc.anomalies[0])")
        }
    }
}
