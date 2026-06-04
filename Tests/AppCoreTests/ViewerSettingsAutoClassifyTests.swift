// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("ViewerSettings — auto-classify")
@MainActor
struct ViewerSettingsAutoClassifyTests {
    private func makeSuite() -> (UserDefaults, String) {
        let name = "test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func defaultsAreEnabledAndTwenty() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        #expect(s.autoClassifyEnabled == true)
        #expect(s.thickBookThreshold == 20)
    }

    @Test func persistsToggleAndThreshold() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }
        do {
            let s = ViewerSettings(defaults: suite)
            s.autoClassifyEnabled = false
            s.thickBookThreshold = 50
        }
        let reloaded = ViewerSettings(defaults: suite)
        #expect(reloaded.autoClassifyEnabled == false)
        #expect(reloaded.thickBookThreshold == 50)
    }

    @Test func recoversFromOutOfRangeStoredThreshold() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }
        suite.set(500, forKey: "thickBookThreshold")  // out of [5...100]
        let s = ViewerSettings(defaults: suite)
        #expect(s.thickBookThreshold == 20)  // default
    }

    @Test func clampsAboveRangeOnAssignment() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.thickBookThreshold = 200
        #expect(s.thickBookThreshold == 100)
        #expect(suite.integer(forKey: "thickBookThreshold") == 100)
    }

    @Test func clampsBelowRangeOnAssignment() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.thickBookThreshold = 0
        #expect(s.thickBookThreshold == 5)
        s.thickBookThreshold = -10
        #expect(s.thickBookThreshold == 5)
    }

    @Test func keepsInRangeAssignmentVerbatim() {
        let (suite, name) = makeSuite()
        defer { suite.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: suite)
        s.thickBookThreshold = 5
        #expect(s.thickBookThreshold == 5)
        s.thickBookThreshold = 100
        #expect(s.thickBookThreshold == 100)
        s.thickBookThreshold = 42
        #expect(s.thickBookThreshold == 42)
    }
}
