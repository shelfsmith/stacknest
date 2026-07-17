// SPDX-License-Identifier: MIT
import Foundation

public enum ViewerIdentity: Hashable, Sendable {
    case local(bundlePath: String, bookID: Int)
    /// G16 C3: オフライン読み出しとリモート読み出しは同一の本を指すため identity を統一する。
    /// `.offline` ケースは撤去済み（DL 済みの本を開く経路もすべてこの `.remote` を使う）。
    case remote(serverID: String, libraryUUID: String, bookID: Int)
}

/// 内蔵ビューア窓の在庫管理の純ロジック（AppKit 非依存・単体テスト可能）。
/// 実 window の focus/close は App 側 glue が担う。
public struct ViewerRegistryCore {
    public init() {}
    public enum BeginDecision: Equatable { case focusExisting, ignore, proceed }

    private var open: Set<ViewerIdentity> = []
    private var opening: Set<ViewerIdentity> = []

    public var openIdentities: Set<ViewerIdentity> { open }
    public var openingIdentities: Set<ViewerIdentity> { opening }

    public mutating func begin(_ id: ViewerIdentity) -> BeginDecision {
        if open.contains(id) { return .focusExisting }
        if opening.contains(id) { return .ignore }
        opening.insert(id)
        return .proceed
    }

    public mutating func finish(_ id: ViewerIdentity, allowMultiple: Bool) -> [ViewerIdentity] {
        opening.remove(id)
        open.insert(id)
        guard !allowMultiple else { return [] }
        let others = open.subtracting([id])
        open = [id]
        return Array(others)
    }

    public mutating func cancel(_ id: ViewerIdentity) { opening.remove(id) }
    public mutating func remove(_ id: ViewerIdentity) { open.remove(id) }

    /// G16 C1: 巻スワップ等で表示中の本の identity が変わったとき、`open` の登録を張り替える。
    /// `from` が `open` に無ければ no-op（`opening` は触らない）。
    public mutating func reidentify(from: ViewerIdentity, to: ViewerIdentity) {
        guard open.contains(from) else { return }
        open.remove(from)
        open.insert(to)
    }
}
