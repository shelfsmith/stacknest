// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("FilenameFormatPreset + logic")
struct FilenameFormatPresetTests {
    @Test func codableRoundTripAndDisplayName() throws {
        let p = FilenameFormatPreset(id: "a", name: "単行本", format: "@author - @title")
        let data = try JSONEncoder().encode([p])
        let back = try JSONDecoder().decode([FilenameFormatPreset].self, from: data)
        #expect(back == [p])
        #expect(p.displayName == "単行本")
        #expect(FilenameFormatPreset(id: "b", name: "  ", format: "@title").displayName == "@title")
    }
    @Test func migrate() {
        let r = FilenameFormatPresetLogic.migrate(existingFormat: "@author @title", id: "x")
        #expect(r.presets == [FilenameFormatPreset(id: "x", name: "既定", format: "@author @title")])
        #expect(r.defaultID == "x")
    }
    @Test func defaultFormatResolution() {
        let ps = [FilenameFormatPreset(id: "1", name: "a", format: "F1"),
                  FilenameFormatPreset(id: "2", name: "b", format: "F2")]
        #expect(FilenameFormatPresetLogic.defaultFormat(in: ps, defaultID: "2") == "F2")
        #expect(FilenameFormatPresetLogic.defaultFormat(in: ps, defaultID: "zzz") == "F1")
        #expect(FilenameFormatPresetLogic.defaultFormat(in: [], defaultID: "x") == "@title")
    }
    @Test func validatedDefaultID() {
        let ps = [FilenameFormatPreset(id: "1", name: "a", format: "F1")]
        #expect(FilenameFormatPresetLogic.validatedDefaultID(presets: ps, requested: "1") == "1")
        #expect(FilenameFormatPresetLogic.validatedDefaultID(presets: ps, requested: "x") == "1")
        #expect(FilenameFormatPresetLogic.validatedDefaultID(presets: [], requested: "x") == "")
    }
    @Test func removingLastIsNoOp() {
        let ps = [FilenameFormatPreset(id: "1", name: "a", format: "F1")]
        let r = FilenameFormatPresetLogic.removing(id: "1", presets: ps, defaultID: "1")
        #expect(r.presets == ps)
        #expect(r.defaultID == "1")
    }
    @Test func removingDefaultReassigns() {
        let ps = [FilenameFormatPreset(id: "1", name: "a", format: "F1"),
                  FilenameFormatPreset(id: "2", name: "b", format: "F2")]
        let r = FilenameFormatPresetLogic.removing(id: "1", presets: ps, defaultID: "1")
        #expect(r.presets.map(\.id) == ["2"])
        #expect(r.defaultID == "2")
    }
}
