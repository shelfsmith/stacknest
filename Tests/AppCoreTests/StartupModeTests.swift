// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("StartupMode")
struct StartupModeTests {
    @Test
    func defaultIsLastOpened() throws {
        #expect(StartupMode.default == .lastOpened)
    }

    @Test
    func encodesAsRawValue() throws {
        #expect(StartupMode.titleScreen.rawValue == "title")
        #expect(StartupMode.lastOpened.rawValue == "lastOpened")
        #expect(StartupMode.fixedLibrary.rawValue == "fixed")
    }

    @Test
    func decodesFromRawValue() throws {
        #expect(StartupMode(rawValue: "title") == .titleScreen)
        #expect(StartupMode(rawValue: "lastOpened") == .lastOpened)
        #expect(StartupMode(rawValue: "fixed") == .fixedLibrary)
        #expect(StartupMode(rawValue: "garbage") == nil)
    }
}
