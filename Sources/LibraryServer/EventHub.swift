// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

/// SSE 購読者へライブイベントを配信するハブ。購読ごとに scope を保持し、
/// publish 時に scope.allows(event.library) を満たす購読者にのみ yield する。
public actor EventHub {
    private struct Subscriber {
        let scope: GrantScope
        let continuation: AsyncStream<LiveEvent>.Continuation
    }
    private var subscribers: [UUID: Subscriber] = [:]
    /// G23 (#15): 対象ライブラリが施錠中かを問い合わせる。
    /// 施錠庫のイベントは粒度を落として配信する（下記 `coarsenIfLocked`）。
    private let isLibraryLocked: @Sendable (String) async -> Bool

    public init(isLibraryLocked: @escaping @Sendable (String) async -> Bool = { _ in false }) {
        self.isLibraryLocked = isLibraryLocked
    }

    public func subscribe(scope: GrantScope) -> (id: UUID, stream: AsyncStream<LiveEvent>) {
        let id = UUID()
        let stream = AsyncStream<LiveEvent> { continuation in
            subscribers[id] = Subscriber(scope: scope, continuation: continuation)
        }
        return (id, stream)
    }

    public func publish(_ event: LiveEvent) async {
        let delivered = await coarsenIfLocked(event)
        for sub in subscribers.values where sub.scope.allows(delivered.library) {
            sub.continuation.yield(delivered)
        }
    }

    /// G23 (#15): 施錠庫の `bookChanged` は `bookID` を落として `structureChanged` に丸める。
    ///
    /// `bookID` は連番のため、未解錠のクライアントに流れると蔵書数の概算が漏れる。
    /// 配信自体は止めない — 止めると解錠して見ている最中もライブ同期が効かず手動リロードが要る。
    /// 丸めても実害はない: クライアントは「変わった」と知って再取得し、その取得は
    /// `LibraryResolver.resolve` のロック判定を通るため、未解錠なら 403 で弾かれる。
    private func coarsenIfLocked(_ event: LiveEvent) async -> LiveEvent {
        guard case .bookChanged(let library, _) = event else { return event }
        return await isLibraryLocked(library) ? .structureChanged(library: library) : event
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.continuation.finish()
    }
}
