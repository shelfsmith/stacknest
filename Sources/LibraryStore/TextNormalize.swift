// SPDX-License-Identifier: MIT
import Foundation
import GRDB

/// 保存前のテキスト正規化。macOS のファイル名は NFD（分解）なので、ファイル名由来の値が
/// NFC（合成済）の入力/インポートと別文字列になる問題を防ぐため、保存値を NFC へ統一する。
/// path / cover 参照には適用しない（FS 形に一致させる必要があるため）。
public enum TextNormalize {
    /// NFC-normalize a non-optional string. Idempotent.
    @inline(__always)
    public static func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

    /// NFC-normalize an optional string; nil passes through as nil. Idempotent.
    @inline(__always)
    public static func nfc(_ s: String?) -> String? { s.map { $0.precomposedStringWithCanonicalMapping } }

    /// NFC-normalize a non-optional string, returning DatabaseValueConvertible? for array literals.
    /// Resolves overload ambiguity when the call site is in a [DatabaseValueConvertible?] context.
    @inline(__always)
    public static func nfcValue(_ s: String) -> DatabaseValueConvertible? { s.precomposedStringWithCanonicalMapping }

    /// NFC-normalize an optional string, returning DatabaseValueConvertible? for array literals.
    @inline(__always)
    public static func nfcValue(_ s: String?) -> DatabaseValueConvertible? { s?.precomposedStringWithCanonicalMapping }
}
