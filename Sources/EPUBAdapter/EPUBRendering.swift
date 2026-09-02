// SPDX-License-Identifier: MIT
import Foundation

/// 契約: 読書ビューを作る。実装（Washi 等）は `WashiEPUBAdapter` に隔離。
public protocol EPUBRendering: Sendable {
    /// `at` があればその位置で開く（`restorable(for:)` は実装側が自分のエンジン名で呼ぶ）。
    @MainActor func makeReaderView(url: URL, at locator: EPUBLocatorValue?) async throws -> any EPUBReaderViewing
}
