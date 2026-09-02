// SPDX-License-Identifier: MIT
import Foundation

/// G48-2: EPUB の読書位置。**共有の正は `spine`＋`progress`**（Washi と foliate-js の両方が出せる）。
/// `cfi` は同じエンジン同士で復元精度を上げる補助。`engine` が違えば捨てる（`restorable(for:)`）。
public struct EPUBLocatorValue: Codable, Equatable, Sendable {
    public let spine: Int
    public let progress: Double
    public let cfi: String?
    public let engine: String?

    public init(spine: Int, progress: Double, cfi: String?, engine: String?) {
        self.spine = max(0, spine)
        self.progress = min(1, max(0, progress))
        self.cfi = cfi
        self.engine = engine
    }

    /// `engine` のエンジンで復元するときの値。他エンジンの `cfi` は無視する。
    public func restorable(for engine: String) -> EPUBLocatorValue {
        guard self.engine == engine else {
            return EPUBLocatorValue(spine: spine, progress: progress, cfi: nil, engine: nil)
        }
        return self
    }
}
