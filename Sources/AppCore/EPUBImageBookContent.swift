// SPDX-License-Identifier: MIT
import Foundation
import EPUBAdapter

/// G48-2b: 全ページ画像の EPUB を既存の画像ビューアに載せる。handle は契約（Washi は見えない）。
/// `lazyURL` 版は巻送り（`BookContentFactory.make` は同期）用で、初回の `pageCount` で開く。
public struct EPUBImageBookContent: BookContent {
    private enum Source: Sendable { case handle(any EPUBImageBookReading); case lazy(URL, Cache) }
    private let source: Source

    /// 最終レビュー Important #2: 成功だけでなく「画像本でない」判定も記憶する（負のキャッシュ）。
    /// resolve はアクター内で完結させ、同時アクセスでも `openImageBook` を 1 回しか呼ばない
    /// （実行中の Task を共有し、await を跨いだ再入で二重に開かせない）。
    private actor Cache {
        enum State { case unresolved, notImageBook, open(any EPUBImageBookReading) }
        private var state: State = .unresolved
        private var inFlight: Task<(any EPUBImageBookReading)?, Error>?

        /// `openImageBook` が nil（=画像本でない）なら `.notImageBook` として記憶し、以後は
        /// ファイルに触れず `unsupported(.text)` を投げる。throw（一時的な I/O エラー等の可能性）は
        /// キャッシュせずそのまま rethrow し、次回また試せるようにする。
        func resolve(url: URL, reader: (any EPUBReading)?) async throws -> any EPUBImageBookReading {
            switch state {
            case .open(let h): return h
            case .notImageBook: throw BookContentError.unsupported(.text)
            case .unresolved: break
            }

            let task: Task<(any EPUBImageBookReading)?, Error>
            if let existing = inFlight {
                task = existing
            } else {
                let newTask = Task<(any EPUBImageBookReading)?, Error> {
                    guard let reader else { return nil }
                    return try await reader.openImageBook(url: url)
                }
                inFlight = newTask
                task = newTask
            }

            let handle: (any EPUBImageBookReading)?
            do {
                handle = try await task.value
            } catch {
                inFlight = nil
                throw error
            }
            inFlight = nil
            guard let handle else {
                state = .notImageBook
                throw BookContentError.unsupported(.text)
            }
            state = .open(handle)
            return handle
        }
    }

    public init(handle: any EPUBImageBookReading) { source = .handle(handle) }
    public init(lazyURL url: URL) { source = .lazy(url, Cache()) }

    private func resolved() async throws -> any EPUBImageBookReading {
        switch source {
        case .handle(let h): return h
        case .lazy(let url, let cache):
            return try await cache.resolve(url: url, reader: EPUBAdapter.reader)
        }
    }
    public var pageCount: Int { get async throws { try await resolved().pageCount } }
    public func imageData(at page: Int) async throws -> Data {
        let h = try await resolved()
        guard page >= 0, page < h.pageCount else { throw BookContentError.pageOutOfRange(page) }
        return try await h.imageData(at: page)
    }
}
