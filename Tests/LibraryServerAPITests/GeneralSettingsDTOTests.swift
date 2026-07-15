// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryServerAPI

@Suite("G12b-3a DTOs")
struct GeneralSettingsDTOTests {
    @Test func generalSettingsRoundTrips() throws {
        let dto = GeneralSettingsDTO(displayName: "My Lib", backupEnabled: true, backupGenerations: 7)
        let back = try JSONDecoder().decode(GeneralSettingsDTO.self, from: try JSONEncoder().encode(dto))
        #expect(back.displayName == "My Lib")
        #expect(back.backupEnabled == true)
        #expect(back.backupGenerations == 7)
    }
    @Test func integrityCheckRoundTrips() throws {
        let dto = IntegrityCheckDTO(healthy: true, rows: ["ok"])
        let back = try JSONDecoder().decode(IntegrityCheckDTO.self, from: try JSONEncoder().encode(dto))
        #expect(back.healthy == true)
        #expect(back.rows == ["ok"])
    }
    @Test func bookDetailFilenameBackwardCompatible() throws {
        // filename 欠落の旧 JSON は nil に decode（後方互換）。
        let json = #"{"id":1,"title":"t","author":null,"genre":null,"path":null,"dateAdded":"2026-01-01T00:00:00Z","playDate":null,"bookType":0,"fileType":0,"pages":null,"lastPage":null,"rating":0,"unseen":false,"keywordA":null,"keywordB":null,"keywordC":null,"neta":null,"memo":null,"series":null,"volume":null,"coverImageName":null,"coverCropRectJSON":null,"pageDirection":null,"fileExtension":"zip"}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let dto = try d.decode(BookDetailDTO.self, from: Data(json.utf8))
        #expect(dto.filename == nil)
        #expect(dto.fileExtension == "zip")
    }
}
