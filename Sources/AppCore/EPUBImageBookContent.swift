// SPDX-License-Identifier: MIT
import Foundation
import EPUBAdapter

/// G48-2b: 全ページ画像の EPUB を既存の画像ビューアに載せる。handle は契約（Washi は見えない）。
/// `lazyURL` 版は巻送り（`BookContentFactory.make` は同期）用で、初回の `pageCount` で開く。
public struct EPUBImageBookContent: BookContent {
    private enum Source: Sendable { case handle(any EPUBImageBookReading); case lazy(URL, Cache) }
    private let source: Source
    private actor Cache { var handle: (any EPUBImageBookReading)?; func set(_ h: any EPUBImageBookReading) { handle = h } }

    public init(handle: any EPUBImageBookReading) { source = .handle(handle) }
    public init(lazyURL url: URL) { source = .lazy(url, Cache()) }

    private func resolved() async throws -> any EPUBImageBookReading {
        switch source {
        case .handle(let h): return h
        case .lazy(let url, let cache):
            if let h = await cache.handle { return h }
            guard let reader = EPUBAdapter.reader,
                  let h = try await reader.openImageBook(url: url) else {
                throw BookContentError.unsupported(.text)
            }
            await cache.set(h); return h
        }
    }
    public var pageCount: Int { get async throws { try await resolved().pageCount } }
    public func imageData(at page: Int) async throws -> Data {
        let h = try await resolved()
        guard page >= 0, page < h.pageCount else { throw BookContentError.pageOutOfRange(page) }
        return try await h.imageData(at: page)
    }
}
