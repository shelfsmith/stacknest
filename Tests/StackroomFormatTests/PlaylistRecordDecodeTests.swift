// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackroomFormat

@Suite("PlaylistRecord decode")
struct PlaylistRecordDecodeTests {
    @Test("Decodes a normal playlist with Items array")
    func decodesNormalPlaylist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Title</key><string>Favorites</string>
            <key>Type</key><integer>0</integer>
            <key>Icon</key><integer>3</integer>
            <key>ItemView</key><true/>
            <key>ToolTab</key><false/>
            <key>Items</key>
            <array>
                <integer>1</integer>
                <integer>5</integer>
                <integer>42</integer>
            </array>
        </dict>
        </plist>
        """
        let playlist = try PropertyListDecoder().decode(PlaylistRecord.self, from: Data(xml.utf8))
        #expect(playlist.title == "Favorites")
        #expect(playlist.type == 0)
        #expect(playlist.icon == 3)
        #expect(playlist.itemView == true)
        #expect(playlist.toolTab == false)
        #expect(playlist.items == [1, 5, 42])
        #expect(playlist.conditions == nil)
    }

    @Test("LibraryDocument decodes Playlists array of size 1")
    func decodesPlaylistsInDocument() throws {
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
                    <key>Title</key><string>B</string>
                    <key>Cover Image Path</key><string>/c</string>
                    <key>Date Added</key><date>2025-01-01T00:00:00Z</date>
                    <key>Book Type</key><integer>0</integer>
                    <key>File Type</key><integer>2</integer>
                </dict>
            </dict>
            <key>Playlists</key>
            <array>
                <dict>
                    <key>Title</key><string>Recent</string>
                    <key>Type</key><integer>1</integer>
                    <key>ItemView</key><false/>
                    <key>ToolTab</key><true/>
                    <key>Items</key>
                    <array>
                        <integer>1</integer>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let doc = try PropertyListDecoder().decode(LibraryDocument.self, from: Data(xml.utf8))
        #expect(doc.books.count == 1)
        #expect(doc.playlists.count == 1)
        #expect(doc.playlists[0].title == "Recent")
        #expect(doc.playlists[0].type == 1)
        #expect(doc.playlists[0].itemView == false)
        #expect(doc.playlists[0].toolTab == true)
        #expect(doc.playlists[0].items == [1])
    }

    @Test("G49: ItemView / ToolTab は真偽値・整数・欠落のいずれでも読める")
    func tolerantBooleans() throws {
        func playlist(_ itemView: String) throws -> PlaylistRecord {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Title</key><string>S</string>
                <key>Type</key><integer>0</integer>
                \(itemView)
            </dict>
            </plist>
            """
            return try PropertyListDecoder().decode(PlaylistRecord.self, from: Data(xml.utf8))
        }
        #expect(try playlist("<key>ItemView</key><true/>").itemView == true)
        #expect(try playlist("<key>ItemView</key><integer>1</integer>").itemView == true)
        #expect(try playlist("<key>ItemView</key><integer>0</integer>").itemView == false)
        #expect(try playlist("").itemView == false)
    }

    @Test("G49: Items・Type が無くても読める")
    func tolerantItemsAndType() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict><key>Title</key><string>S</string></dict>
        </plist>
        """
        let p = try PropertyListDecoder().decode(PlaylistRecord.self, from: Data(xml.utf8))
        #expect(p.items.isEmpty)
        #expect(p.type == 0)
        #expect(p.conditionsUnreadable == false)
    }

    @Test("G49: 壊れたプレイリストが 1 件あっても残りは生き残る（症状の回帰テスト）")
    func oneBadPlaylistDoesNotWipeTheRest() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Books</key><dict/>
            <key>Playlists</key>
            <array>
                <dict><key>Title</key><string>A</string><key>Type</key><integer>0</integer></dict>
                <dict><key>Type</key><integer>0</integer></dict>
                <dict><key>Title</key><string>C</string><key>Type</key><integer>0</integer></dict>
            </array>
        </dict>
        </plist>
        """
        let doc = try PropertyListDecoder().decode(LibraryDocument.self, from: Data(xml.utf8))
        #expect(doc.playlists.map(\.title) == ["A", "C"])
        #expect(doc.playlistAnomalies.count == 1)
    }
}
