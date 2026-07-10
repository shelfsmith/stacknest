// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("WatchedFolder subfolderMode Codable")
struct WatchedFolderCodableTests {
    @Test func oldJSONWithoutSubfolderModeDefaultsToTopLevelOnly() throws {
        let json = #"{"id":"x","path":"/p","enabled":true,"presetID":null,"baseline":[]}"#
        let f = try JSONDecoder().decode(WatchedFolder.self, from: Data(json.utf8))
        #expect(f.subfolderMode == .topLevelOnly)
        #expect(f.path == "/p")
    }
    @Test func recurseDecodesAndRoundTrips() throws {
        let f0 = WatchedFolder(id: "y", path: "/q", subfolderMode: .recurse)
        let data = try JSONEncoder().encode(f0)
        let f1 = try JSONDecoder().decode(WatchedFolder.self, from: data)
        #expect(f1.subfolderMode == .recurse)
        #expect(f1 == f0)
    }
    @Test func explicitTopLevelDecodes() throws {
        let json = #"{"id":"z","path":"/r","enabled":true,"presetID":null,"baseline":[],"subfolderMode":"topLevelOnly"}"#
        let f = try JSONDecoder().decode(WatchedFolder.self, from: Data(json.utf8))
        #expect(f.subfolderMode == .topLevelOnly)
    }
}
