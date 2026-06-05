// SPDX-License-Identifier: MIT
import Foundation

// ICU collation API — available via libicucore embedded in macOS.
// `@_silgen_name` resolves the C symbols at link time without a C bridging header.
// U_USING_FALLBACK_WARNING = -128 is a success-with-fallback warning (not an error).

@_silgen_name("ucol_open")
private func ucol_open(
    _ locale: UnsafePointer<CChar>?,
    _ err: UnsafeMutablePointer<Int32>?
) -> OpaquePointer?

@_silgen_name("ucol_getSortKey")
private func ucol_getSortKey(
    _ collator: OpaquePointer?,
    _ source: UnsafePointer<UInt16>?,
    _ sourceLength: Int32,
    _ result: UnsafeMutablePointer<UInt8>?,
    _ resultLength: Int32
) -> Int32

@_silgen_name("ucol_close")
private func ucol_close(_ collator: OpaquePointer?)

// MARK: - Collator cache

/// 一度作成したコレーターはスレッドセーフに再利用する（コレーターは読み取り専用）。
/// U_USING_FALLBACK_WARNING(=-128) は警告であり、コレーターは正常に生成される。
/// `nonisolated(unsafe)` は「ICU コレーターは生成後に内部状態を変更しない」ことを根拠とする。
private enum Collators {
    /// numeric=false: localizedCaseInsensitiveCompare 相当
    nonisolated(unsafe) static let caseInsensitive: OpaquePointer? = {
        let locale = "\(Locale.current.identifier)@colStrength=secondary"
        var status: Int32 = 0
        return ucol_open(locale, &status)
    }()

    /// numeric=true: localizedStandardCompare 相当（数値自然順）
    nonisolated(unsafe) static let standard: OpaquePointer? = {
        let locale = "\(Locale.current.identifier)@colNumeric=yes;colStrength=quaternary"
        var status: Int32 = 0
        return ucol_open(locale, &status)
    }()
}

// MARK: - Public API

/// localized 照合キー。バイト辞書比較（`lexicographicallyPrecedes` / `==`）の結果が
/// `localized*Compare` と一致するバイナリキーを返す。
///
/// - Parameters:
///   - s: 対象文字列
///   - numeric: `true` → `localizedStandardCompare` 相当（数値自然順 + ロケール + 大小無視）
///              `false` → `localizedCaseInsensitiveCompare` 相当（ロケール + 大小無視）
/// - Returns: ゼロ終端バイト列。`lexicographicallyPrecedes` でバイト辞書比較可能。
public func localizedSortKey(_ s: String, numeric: Bool) -> [UInt8] {
    guard !s.isEmpty else { return [] }
    guard let col = numeric ? Collators.standard : Collators.caseInsensitive else {
        // Collator could not be created (should not happen on macOS).
        // Fall back to the string itself encoded as UTF-8.
        return Array(s.utf8)
    }
    let chars = Array(s.utf16)
    return chars.withUnsafeBufferPointer { ptr -> [UInt8] in
        // First call with nil buffer returns the required buffer size (including NUL terminator).
        let needed = ucol_getSortKey(col, ptr.baseAddress, Int32(chars.count), nil, 0)
        guard needed > 0 else { return [] }
        var buf = [UInt8](repeating: 0, count: Int(needed))
        let written = ucol_getSortKey(col, ptr.baseAddress, Int32(chars.count), &buf, needed)
        // `written` includes the NUL terminator; trim to actual written count.
        if written > 0 && written < needed {
            buf.removeLast(Int(needed - written))
        }
        return buf
    }
}
