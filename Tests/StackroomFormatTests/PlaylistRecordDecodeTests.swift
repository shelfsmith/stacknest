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
}
