// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("AppPreferences.sharingWarningSuppressed")
struct SharingWarningPrefTests {
    @Test func defaultsFalseAndPersists() {
        let key = "sharing_warning_suppressed"
        UserDefaults.standard.removeObject(forKey: key)
        #expect(AppPreferences.sharingWarningSuppressed == false)  // 既定 false（警告を出す）
        AppPreferences.sharingWarningSuppressed = true
        #expect(AppPreferences.sharingWarningSuppressed == true)
        UserDefaults.standard.removeObject(forKey: key)            // 後始末
    }
}
