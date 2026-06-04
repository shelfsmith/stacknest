// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

// UserDefaults.standard を触るため並列実行で race condition が起きる。.serialized で順次実行。
@Suite("AppPreferences — UserDefaults round-trip", .serialized)
struct AppPreferencesTests {

    @Test
    func confirmDeleteDefaultsToTrue() {
        // Remove the key to simulate first-launch state
        UserDefaults.standard.removeObject(forKey: AppPreferences.confirmDeleteFromLibraryKey)
        #expect(AppPreferences.confirmDeleteFromLibrary == true)
    }

    @Test
    func confirmDeleteRoundtrip() {
        // Set to false and read back
        AppPreferences.confirmDeleteFromLibrary = false
        #expect(AppPreferences.confirmDeleteFromLibrary == false)

        // Restore to true and read back
        AppPreferences.confirmDeleteFromLibrary = true
        #expect(AppPreferences.confirmDeleteFromLibrary == true)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: AppPreferences.confirmDeleteFromLibraryKey)
    }

    @Test
    func firstRunWizardDefaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: AppPreferences.hasCompletedFirstRunWizardKey)
        #expect(AppPreferences.hasCompletedFirstRunWizard == false)
    }

    @Test
    func firstRunWizardRoundtrip() {
        AppPreferences.hasCompletedFirstRunWizard = true
        #expect(AppPreferences.hasCompletedFirstRunWizard == true)

        AppPreferences.hasCompletedFirstRunWizard = false
        #expect(AppPreferences.hasCompletedFirstRunWizard == false)

        UserDefaults.standard.removeObject(forKey: AppPreferences.hasCompletedFirstRunWizardKey)
    }
}
