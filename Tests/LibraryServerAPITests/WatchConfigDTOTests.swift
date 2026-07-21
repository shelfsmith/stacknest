// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServerAPI

@Suite("WatchConfigDTO (G12b-2c)")
struct WatchConfigDTOTests {
    @Test func subfolderModeDefaultsWhenAbsent() throws {
        // 旧 JSON（subfolderMode 欠落）は .topLevelOnly に decode される（後方互換）
        let json = #"{"id":"f1","path":"/x","enabled":true,"baseline":[]}"#
        let dto = try JSONDecoder().decode(WatchedFolderDTO.self, from: Data(json.utf8))
        #expect(dto.subfolderMode == .topLevelOnly)
    }

    @Test func subfolderModeRoundTrips() throws {
        let f = WatchedFolderDTO(id: "f1", path: "/x", enabled: true, subfolderMode: .recurse)
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(WatchedFolderDTO.self, from: data)
        #expect(back.subfolderMode == .recurse)
    }

    // G9b Task3: archive も DTO で raw 値パススルーでラウンドトリップすること。
    @Test func subfolderModeArchiveRoundTrips() throws {
        let f = WatchedFolderDTO(id: "f1", path: "/x", enabled: true, subfolderMode: .archive)
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(WatchedFolderDTO.self, from: data)
        #expect(back.subfolderMode == .archive)
        // raw 値そのものも "archive" であること（後方互換の生値契約）。
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains(#""subfolderMode":"archive""#))
    }

    @Test func presetsOptionalDecodesNil() throws {
        let json = #"{"enabled":true,"folders":[]}"#
        let cfg = try JSONDecoder().decode(WatchConfigDTO.self, from: Data(json.utf8))
        #expect(cfg.presets == nil)
    }

    @Test func presetsRoundTrip() throws {
        let cfg = WatchConfigDTO(enabled: false, folders: [],
                                 presets: [FilenameFormatPresetDTO(id: "p1", name: "コミック")])
        let back = try JSONDecoder().decode(WatchConfigDTO.self, from: try JSONEncoder().encode(cfg))
        #expect(back.presets?.first?.name == "コミック")
    }
}
