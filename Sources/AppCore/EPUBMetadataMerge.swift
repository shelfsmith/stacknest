// SPDX-License-Identifier: MIT
import Foundation

/// G48: EPUB のメタデータは**既存の値が空のときだけ**採る。取り込み後にユーザーが直した値を壊さない。
public enum EPUBMetadataMerge {
    public static func merged(existing: String?, fromEPUB: String?) -> String? {
        if let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return existing }
        guard let fromEPUB, !fromEPUB.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return existing }
        return fromEPUB
    }
}
