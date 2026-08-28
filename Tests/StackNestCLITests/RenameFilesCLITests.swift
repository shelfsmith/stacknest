// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServerAPI

@Suite("rename-files のリクエスト組み立て")
struct RenameFilesCLITests {
    @Test("既定では apply が false")
    func defaultsToPlanOnly() throws {
        let body = RenameFilesRequest(ids: [1, 2])
        #expect(body.apply == false)
        let json = try JSONEncoder().encode(body)
        let decoded = try JSONDecoder().decode(RenameFilesRequest.self, from: json)
        #expect(decoded.apply == false)
        #expect(decoded.ids == [1, 2])
    }

    @Test("preset と format は素通りする")
    func carriesPresetAndFormat() throws {
        let body = RenameFilesRequest(ids: [1], format: "@series v@volume", apply: true)
        let decoded = try JSONDecoder().decode(RenameFilesRequest.self,
                                               from: try JSONEncoder().encode(body))
        #expect(decoded.format == "@series v@volume")
        #expect(decoded.presetID == nil)
        #expect(decoded.apply == true)
    }
}
