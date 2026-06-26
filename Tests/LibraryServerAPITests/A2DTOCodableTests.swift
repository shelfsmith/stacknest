// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServerAPI

@Suite("A2 DTOs")
struct A2DTOCodableTests {
    @Test func importConfigNullable() throws {
        let data = Data(#"{"autoClassifyEnabled":null,"thickBookThreshold":30}"#.utf8)
        let dto = try JSONDecoder().decode(ImportConfigDTO.self, from: data)
        #expect(dto.autoClassifyEnabled == nil)
        #expect(dto.thickBookThreshold == 30)
    }
    @Test func watchConfigRoundTrips() throws {
        let f = WatchedFolderDTO(id: "x", path: "/a", enabled: true, presetID: nil, baseline: [])
        let cfg = WatchConfigDTO(enabled: true, folders: [f])
        let back = try JSONDecoder().decode(WatchConfigDTO.self, from: JSONEncoder().encode(cfg))
        #expect(back.folders.first?.path == "/a")
    }
}
