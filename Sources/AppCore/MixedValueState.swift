// SPDX-License-Identifier: MIT
import Foundation

/// Represents whether a set of values are all the same (.unanimous) or differ (.mixed).
/// Used by detail pane to render fields with `<複数値>` placeholder when a
/// multi-selection has differing values for that field.
public enum MixedValueState<T: Equatable & Sendable>: Equatable, Sendable {
    case unanimous(T)
    case mixed

    /// Compute state from a collection. Returns `.mixed` for empty input.
    public static func from<S: Collection>(_ values: S) -> MixedValueState<T>
    where S.Element == T {
        guard let first = values.first else { return .mixed }
        return values.allSatisfy({ $0 == first }) ? .unanimous(first) : .mixed
    }
}

/// Helpers for `MixedValueState<Double?>` used by VolumeEditorField.
public extension MixedValueState where T == Double? {
    /// Returns true when the 消去 context menu action should be offered.
    /// True when the state holds a non-nil value, or when values are mixed
    /// (clearing is meaningful in both cases).
    var shouldShowClearAction: Bool {
        switch self {
        case .unanimous(let v): return v != nil
        case .mixed: return true
        }
    }
}
