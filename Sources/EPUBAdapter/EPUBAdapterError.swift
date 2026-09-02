// SPDX-License-Identifier: MIT
public enum EPUBAdapterError: Error, Equatable, Sendable {
    /// 実装側のエラー文言をそのまま持つ（型は外に漏らさない）。
    case cannotOpen(String)
}
