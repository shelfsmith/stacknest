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

    public init() {}

    public func subscribe(scope: GrantScope) -> (id: UUID, stream: AsyncStream<LiveEvent>) {
        let id = UUID()
        let stream = AsyncStream<LiveEvent> { continuation in
            subscribers[id] = Subscriber(scope: scope, continuation: continuation)
        }
        return (id, stream)
    }

    public func publish(_ event: LiveEvent) {
        for sub in subscribers.values where sub.scope.allows(event.library) {
            sub.continuation.yield(event)
        }
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.continuation.finish()
    }
}
