// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

// UserDefaults.standard を共有するため直列実行（AppPreferencesTests と同方針）
@Suite("AppPreferences.sharingWarningSuppressed", .serialized)
struct SharingWarningPrefTests {
    @Test func defaultsFalseAndPersists() {
        let key = AppPreferences.sharingWarningSuppressedKey
        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppPreferences.sharingWarningSuppressed == false)  // 既定 false（警告を出す）
        AppPreferences.sharingWarningSuppressed = true
        #expect(AppPreferences.sharingWarningSuppressed == true)
        UserDefaults.standard.removeObject(forKey: key)            // 後始末
    }
}
