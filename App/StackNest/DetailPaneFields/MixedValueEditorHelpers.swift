// SPDX-License-Identifier: MIT
import Foundation
import AppCore

/// Helpers for binding `MixedValueState<String>` to text editing controls
/// (EditableTextField, EditableTextEditor). Centralizes the no-op detection
/// rules so single-line and multi-line editors stay in sync.
extension MixedValueState where T == String {
    /// Initial text value to display in the editor for this state.
    /// Mixed → empty string. Unanimous → the value itself.
    var editorText: String {
        if case .unanimous(let v) = self { return v }
        return ""
    }

    /// Returns true when committing `text` would be a no-op for this state:
    /// - unanimous and text equals the existing value
    /// - mixed and text is still empty (user didn't type anything)
    func isNoOpCommit(_ text: String) -> Bool {
        switch self {
        case .unanimous(let v) where v == text: return true
        case .mixed where text.isEmpty: return true
        default: return false
        }
    }
}
