// SPDX-License-Identifier: MIT
import Foundation

/// アプリ全体の設定 (UserDefaults backed)。
/// per-library 設定は LibrarySettings、アプリ全般は AppPreferences。
public enum AppPreferences {
    public static let confirmDeleteFromLibraryKey = "confirmDeleteFromLibrary"

    /// 「ライブラリから削除」前に確認 dialog を表示するか (default: true)
    public static var confirmDeleteFromLibrary: Bool {
        get {
            // UserDefaults の未登録時は true (default ON)
            if UserDefaults.standard.object(forKey: confirmDeleteFromLibraryKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: confirmDeleteFromLibraryKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: confirmDeleteFromLibraryKey)
        }
    }

    public static let sharingWarningSuppressedKey = "sharing_warning_suppressed"

    /// 4.2c-10: リモート共有の著作権警告を今後表示しないか（default: false = 表示する）。
    public static var sharingWarningSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: sharingWarningSuppressedKey) }
        set { UserDefaults.standard.set(newValue, forKey: sharingWarningSuppressedKey) }
    }

    public static let hasCompletedFirstRunWizardKey = "stacknest.hasCompletedFirstRunWizard"

    /// 初回起動ウィザードを完了したか (default: false = 未完了 → 起動時にウィザード表示)。
    /// UserDefaults 未登録時は bool(forKey:) が false を返すのでそのまま既定 false になる。
    public static var hasCompletedFirstRunWizard: Bool {
        get { UserDefaults.standard.bool(forKey: hasCompletedFirstRunWizardKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasCompletedFirstRunWizardKey) }
    }
}
