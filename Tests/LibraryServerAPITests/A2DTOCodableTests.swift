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

    @Test("G54-S4: 新しい鍵が往復でき、古い JSON（鍵なし）も読める")
    func importConfigPreferEPUBTitleRoundTrips() throws {
        // 1. 新しい鍵を入れて encode → decode で戻ること（per-library / global 両方）
        let cfg = ImportConfigDTO(autoClassifyEnabled: true, thickBookThreshold: 30, preferEPUBTitle: true)
        let cfgBack = try JSONDecoder().decode(ImportConfigDTO.self, from: JSONEncoder().encode(cfg))
        #expect(cfgBack.preferEPUBTitle == true)

        let global = GlobalImportConfigDTO(autoClassifyEnabled: true, thickBookThreshold: 30, preferEPUBTitle: true)
        let globalBack = try JSONDecoder().decode(GlobalImportConfigDTO.self, from: JSONEncoder().encode(global))
        #expect(globalBack.preferEPUBTitle == true)

        // 2. 鍵を持たない JSON（古い保存データ相当）を decode して、Optional 側は nil・非 Optional 側は既定 false になること
        let oldConfigJSON = Data(#"{"autoClassifyEnabled":null,"thickBookThreshold":30}"#.utf8)
        let oldConfig = try JSONDecoder().decode(ImportConfigDTO.self, from: oldConfigJSON)
        #expect(oldConfig.preferEPUBTitle == nil)

        let oldGlobalJSON = Data(#"{"autoClassifyEnabled":true,"thickBookThreshold":20}"#.utf8)
        let oldGlobal = try JSONDecoder().decode(GlobalImportConfigDTO.self, from: oldGlobalJSON)
        #expect(oldGlobal.preferEPUBTitle == false)
    }
}
