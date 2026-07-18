// SPDX-License-Identifier: MIT
import Foundation

/// 内蔵ビューアのページ送り方向。既定は右→左（漫画想定）。
/// LibraryStore に配置することで、BookPatch / BookRow / AppCore / App 層が
/// 共通の型として参照できる（AppCore → LibraryStore 依存は既存）。
public enum PageDirection: String, Codable, Sendable, CaseIterable {
    case rightToLeft
    case leftToRight

    public static let defaultValue: PageDirection = .rightToLeft
}
