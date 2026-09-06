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
    /// G49: `Playlists` 配列の要素単位デコードで発生した異常（壊れた 1 件・条件破損）の記録。
    public let playlistAnomalies: [PlaylistAnomaly]

    public init(
        books: [String: BookRecord],
        anomalies: [BookAnomaly] = [],
        playlists: [PlaylistRecord] = [],
        playlistAnomalies: [PlaylistAnomaly] = []
    ) {
        self.books = books
        self.anomalies = anomalies
        self.playlists = playlists
        self.playlistAnomalies = playlistAnomalies
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

    /// G49: `UnkeyedDecodingContainer.decode(_:)` は、要素の `init(from:)` が throw した場合に
    /// currentIndex を進めない実装があり得る（無限ループの温床）。このラッパーは**常に成功する**ので、
    /// `array.decode(PlaylistEntryResult.self)` は必ず 1 要素消費して次へ進む。
    private struct PlaylistEntryResult: Decodable {
        let record: PlaylistRecord?
        let underlying: String?

        init(from decoder: Decoder) throws {
            do {
                record = try PlaylistRecord(from: decoder)
                underlying = nil
            } catch {
                record = nil
                underlying = String(describing: error)
            }
        }
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

        // G49: `Playlists` 配列も要素単位でデコードする。以前は配列全体を `try?` で
        // 握り潰していたため、1 件の破損プレイリストで全シェルフが消えていた。
        var playlists: [PlaylistRecord] = []
        var playlistAnomalies: [PlaylistAnomaly] = []
        if root.contains(.playlists) {
            do {
                var array = try root.nestedUnkeyedContainer(forKey: .playlists)
                var index = 0
                while !array.isAtEnd {
                    let result = try array.decode(PlaylistEntryResult.self)
                    if let playlist = result.record {
                        if playlist.conditionsUnreadable {
                            playlistAnomalies.append(.unreadableConditions(title: playlist.title))
                        }
                        if playlist.itemsUnreadable {
                            playlistAnomalies.append(.unreadableItems(title: playlist.title))
                        }
                        playlists.append(playlist)
                    } else {
                        playlistAnomalies.append(
                            .malformedPlaylistEntry(index: index, underlying: result.underlying ?? "unknown")
                        )
                    }
                    index += 1
                }
            } catch {
                // `Playlists` はあるのに配列ではない。0 件で返すと「シェルフの無い書庫」と
                // 区別が付かないので、必ず記録する。
                playlistAnomalies.append(.playlistsNotAnArray(underlying: String(describing: error)))
            }
        }

        self.books = books
        self.anomalies = anomalies
        self.playlists = playlists
        self.playlistAnomalies = playlistAnomalies
    }
}
