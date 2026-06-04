// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackroomFormat

@Suite("BookRecord decode")
struct BookRecordDecodeTests {
    @Test("Decodes id and title from minimal plist")
    func decodesMinimalBook() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ID</key><integer>1</integer>
            <key>Title</key><string>Test Book</string>
            <key>Cover Image Path</key><string>/dummy</string>
            <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
            <key>Book Type</key><integer>0</integer>
            <key>File Type</key><integer>2</integer>
        </dict>
        </plist>
        """
        let book = try PropertyListDecoder().decode(BookRecord.self, from: Data(xml.utf8))
        #expect(book.id == 1)
        #expect(book.title == "Test Book")
    }

    @Test("Decodes core string fields from a plist")
    func decodesCoreStringFields() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ID</key><integer>1</integer>
            <key>Title</key><string>Test Book</string>
            <key>Author</key><string>Test Author</string>
            <key>Genre</key><string>test-genre</string>
            <key>Cover Image Path</key><string>/test/cover.zip</string>
            <key>Cover Image Name</key><string>thumb.jpg</string>
            <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
            <key>Book Type</key><integer>0</integer>
            <key>File Type</key><integer>2</integer>
        </dict>
        </plist>
        """
        let book = try PropertyListDecoder().decode(BookRecord.self, from: Data(xml.utf8))
        #expect(book.id == 1)
        #expect(book.title == "Test Book")
        #expect(book.author == "Test Author")
        #expect(book.genre == "test-genre")
        #expect(book.coverImagePath == "/test/cover.zip")
        #expect(book.coverImageName == "thumb.jpg")
    }

    @Test("Author and CoverImageName are optional")
    func optionalFieldsCanBeAbsent() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ID</key><integer>2</integer>
            <key>Title</key><string>Solo</string>
            <key>Genre</key><string>g</string>
            <key>Cover Image Path</key><string>/p</string>
            <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
            <key>Book Type</key><integer>0</integer>
            <key>File Type</key><integer>2</integer>
        </dict>
        </plist>
        """
        let book = try PropertyListDecoder().decode(BookRecord.self, from: Data(xml.utf8))
        #expect(book.author == nil)
        #expect(book.coverImageName == nil)
    }

    @Test("Path field is optional and decodes when present")
    func pathFieldOptional() throws {
        let withPath = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ID</key><integer>1</integer>
            <key>Title</key><string>P</string>
            <key>Genre</key><string>g</string>
            <key>Cover Image Path</key><string>/c</string>
            <key>Path</key><string>/items/p.zip</string>
            <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
            <key>Book Type</key><integer>0</integer>
            <key>File Type</key><integer>2</integer>
        </dict>
        </plist>
        """
        let book = try PropertyListDecoder().decode(BookRecord.self, from: Data(withPath.utf8))
        #expect(book.path == "/items/p.zip")

        let withoutPath = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ID</key><integer>2</integer>
            <key>Title</key><string>Q</string>
            <key>Genre</key><string>g</string>
            <key>Cover Image Path</key><string>/c</string>
            <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
            <key>Book Type</key><integer>0</integer>
            <key>File Type</key><integer>2</integer>
        </dict>
        </plist>
        """
        let book2 = try PropertyListDecoder().decode(BookRecord.self, from: Data(withoutPath.utf8))
        #expect(book2.path == nil)
    }

    @Test("Decodes Date Added (required) and Play Date (optional)")
    func decodesDates() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ID</key><integer>1</integer>
            <key>Title</key><string>D</string>
            <key>Genre</key><string>g</string>
            <key>Cover Image Path</key><string>/c</string>
            <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
            <key>Play Date</key><date>2026-04-15T12:34:56Z</date>
            <key>Book Type</key><integer>0</integer>
            <key>File Type</key><integer>2</integer>
        </dict>
        </plist>
        """
        let book = try PropertyListDecoder().decode(BookRecord.self, from: Data(xml.utf8))
        let added = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")
        let played = ISO8601DateFormatter().date(from: "2026-04-15T12:34:56Z")
        #expect(book.dateAdded == added)
        #expect(book.playDate == played)
    }

    @Test("Decodes Book Type / File Type / Pages")
    func decodesIntFields() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ID</key><integer>1</integer>
            <key>Title</key><string>I</string>
            <key>Genre</key><string>g</string>
            <key>Cover Image Path</key><string>/c</string>
            <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
            <key>Book Type</key><integer>0</integer>
            <key>File Type</key><integer>2</integer>
            <key>Pages</key><integer>201</integer>
        </dict>
        </plist>
        """
        let book = try PropertyListDecoder().decode(BookRecord.self, from: Data(xml.utf8))
        #expect(book.bookType == 0)
        #expect(book.fileType == 2)
        #expect(book.pages == 201)
    }

    @Test("My Rate is clamped to 0..5 (negative -> 0, >5 -> 5, valid -> kept, missing -> 0)")
    func myRateIsClamped() throws {
        func makeXML(rateLine: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>ID</key><integer>1</integer>
                <key>Title</key><string>R</string>
                <key>Genre</key><string>g</string>
                <key>Cover Image Path</key><string>/c</string>
                <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
                <key>Book Type</key><integer>0</integer>
                <key>File Type</key><integer>2</integer>
            \(rateLine)
            </dict>
            </plist>
            """
        }

        let bookHigh = try PropertyListDecoder().decode(
            BookRecord.self,
            from: Data(makeXML(rateLine: "    <key>My Rate</key><integer>9</integer>").utf8)
        )
        #expect(bookHigh.myRate == 5)

        let bookLow = try PropertyListDecoder().decode(
            BookRecord.self,
            from: Data(makeXML(rateLine: "    <key>My Rate</key><integer>-3</integer>").utf8)
        )
        #expect(bookLow.myRate == 0)

        let bookMid = try PropertyListDecoder().decode(
            BookRecord.self,
            from: Data(makeXML(rateLine: "    <key>My Rate</key><integer>3</integer>").utf8)
        )
        #expect(bookMid.myRate == 3)

        let bookMissing = try PropertyListDecoder().decode(
            BookRecord.self,
            from: Data(makeXML(rateLine: "").utf8)
        )
        #expect(bookMissing.myRate == 0)
    }

    @Test("Unseen normalizes bool/int/missing into Bool")
    func unseenNormalization() throws {
        func makeXML(unseenLine: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>ID</key><integer>1</integer>
                <key>Title</key><string>U</string>
                <key>Genre</key><string>g</string>
                <key>Cover Image Path</key><string>/c</string>
                <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
                <key>Book Type</key><integer>0</integer>
                <key>File Type</key><integer>2</integer>
            \(unseenLine)
            </dict>
            </plist>
            """
        }

        // bool true → true
        let boolTrue = try PropertyListDecoder().decode(
            BookRecord.self,
            from: Data(makeXML(unseenLine: "    <key>Unseen</key><true/>").utf8)
        )
        #expect(boolTrue.unseen == true)

        // bool false → false
        let boolFalse = try PropertyListDecoder().decode(
            BookRecord.self,
            from: Data(makeXML(unseenLine: "    <key>Unseen</key><false/>").utf8)
        )
        #expect(boolFalse.unseen == false)

        // int >= 1 → true
        let intOne = try PropertyListDecoder().decode(
            BookRecord.self,
            from: Data(makeXML(unseenLine: "    <key>Unseen</key><integer>1</integer>").utf8)
        )
        #expect(intOne.unseen == true)

        // int 0 → false
        let intZero = try PropertyListDecoder().decode(
            BookRecord.self,
            from: Data(makeXML(unseenLine: "    <key>Unseen</key><integer>0</integer>").utf8)
        )
        #expect(intZero.unseen == false)

        // missing → false
        let missing = try PropertyListDecoder().decode(
            BookRecord.self,
            from: Data(makeXML(unseenLine: "").utf8)
        )
        #expect(missing.unseen == false)
    }

    @Test("Decodes Keyword A/B/C and Neta as optional strings")
    func decodesKeywords() throws {
        let withAll = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ID</key><integer>1</integer>
            <key>Title</key><string>K</string>
            <key>Genre</key><string>g</string>
            <key>Cover Image Path</key><string>/c</string>
            <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
            <key>Book Type</key><integer>0</integer>
            <key>File Type</key><integer>2</integer>
            <key>Keyword A</key><string>alpha</string>
            <key>Keyword B</key><string>beta</string>
            <key>Keyword C</key><string>gamma</string>
            <key>Neta</key><string>spoiler</string>
        </dict>
        </plist>
        """
        let book = try PropertyListDecoder().decode(BookRecord.self, from: Data(withAll.utf8))
        #expect(book.keywordA == "alpha")
        #expect(book.keywordB == "beta")
        #expect(book.keywordC == "gamma")
        #expect(book.neta == "spoiler")

        let withoutAny = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>ID</key><integer>2</integer>
            <key>Title</key><string>NK</string>
            <key>Genre</key><string>g</string>
            <key>Cover Image Path</key><string>/c</string>
            <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
            <key>Book Type</key><integer>0</integer>
            <key>File Type</key><integer>2</integer>
        </dict>
        </plist>
        """
        let bookEmpty = try PropertyListDecoder().decode(BookRecord.self, from: Data(withoutAny.utf8))
        #expect(bookEmpty.keywordA == nil)
        #expect(bookEmpty.keywordB == nil)
        #expect(bookEmpty.keywordC == nil)
        #expect(bookEmpty.neta == nil)
    }
}
