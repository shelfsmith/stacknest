// SPDX-License-Identifier: MIT
import Foundation

public enum ViewerIdentity: Hashable, Sendable {
    case local(bundlePath: String, bookID: Int)
    case offline(serverID: String, libraryUUID: String, bookID: Int)
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
}
