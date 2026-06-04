// SPDX-License-Identifier: MIT
import Foundation

/// Top-level Stackroom library Codable. Spec 1 expands incrementally.
///
/// Decoding is **resilient**: each `Books` entry is decoded individually so a
/// single malformed entry does not abort the whole import. Failures are
/// collected into `anomalies` and surfaced via `LibraryImporter`'s skip log.
public struct LibraryDocument: Sendable {
    public let books: [String: BookRecord]
    public let anomalies: [BookAnomaly]
    public let playlists: [PlaylistRecord]

    public init(
        books: [String: BookRecord],
        anomalies: [BookAnomaly] = [],
        playlists: [PlaylistRecord] = []
    ) {
        self.books = books
        self.anomalies = anomalies
        self.playlists = playlists
    }

    /// Throws `BookAnomaly.dictKeyNotInteger` if `rawKey` is not parseable as Int.
    public static func validateDictKey(_ rawKey: String) throws -> Int {
        guard let i = Int(rawKey) else {
            throw BookAnomaly.dictKeyNotInteger(rawKey: rawKey)
        }
        return i
    }
}

// MARK: - Resilient Decodable

extension LibraryDocument: Decodable {
    private enum RootKeys: String, CodingKey {
        case books     = "Books"
        case playlists = "Playlists"
    }

    /// Dynamic-key wrapper for iterating arbitrary string-keyed dicts.
    private struct AnyStringKey: CodingKey {
        var stringValue: String
        var intValue: Int? { Int(stringValue) }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.stringValue = String(intValue) }
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)

        var books: [String: BookRecord] = [:]
        var anomalies: [BookAnomaly] = []

        let booksContainer = try root.nestedContainer(keyedBy: AnyStringKey.self, forKey: .books)
        for key in booksContainer.allKeys {
            // Step 1: attempt to decode the BookRecord entry. If the value isn't
            // a well-formed book dict (e.g. it's an integer), report
            // `.malformedBookEntry` and move on.
            let book: BookRecord
            do {
                book = try booksContainer.decode(BookRecord.self, forKey: key)
            } catch {
                anomalies.append(
                    .malformedBookEntry(rawKey: key.stringValue, underlying: String(describing: error))
                )
                continue
            }
            // Step 2: only well-formed entries are subject to dict-key validation.
            if (try? LibraryDocument.validateDictKey(key.stringValue)) == nil {
                anomalies.append(.dictKeyNotInteger(rawKey: key.stringValue))
                continue
            }
            books[key.stringValue] = book
        }

        let playlists = (try? root.decode([PlaylistRecord].self, forKey: .playlists)) ?? []

        self.books = books
        self.anomalies = anomalies
        self.playlists = playlists
    }
}
