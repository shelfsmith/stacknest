// SPDX-License-Identifier: MIT
import Foundation

/// Mutable diff applied to one or more BookRow records.
/// Each field is optional — nil means "leave existing value unchanged".
///
/// To explicitly clear a nullable field back to SQL NULL, use the dedicated
/// clear flags: clearSeries / clearVolume. These take precedence over the
/// series / volume fields when building the UPDATE statement.
public struct BookPatch: Sendable, Equatable {
    public var title: String?
    public var author: String?
    public var keywordA: String?
    public var keywordB: String?
    public var keywordC: String?
    public var genre: String?
    public var neta: String?
    public var memo: String?
    public var rating: Int?
    public var unseen: Bool?
    public var bookType: Int?
    public var series: String?
    public var volume: Double?
    public var coverImageName: String?
    /// Phase 2.6b-2 D1: per-book page direction (nil = inherit global).
    public var pageDirection: PageDirection?

    /// When true, sets series = NULL regardless of the `series` field value.
    public var clearSeries: Bool
    /// When true, sets volume = NULL regardless of the `volume` field value.
    public var clearVolume: Bool
    /// When true, sets cover_image_name = NULL regardless of the `coverImageName` field value.
    public var clearCoverImageName: Bool
    /// When true, sets page_direction = NULL regardless of the `pageDirection` field value.
    public var clearPageDirection: Bool

    public init(
        title: String? = nil,
        author: String? = nil,
        keywordA: String? = nil,
        keywordB: String? = nil,
        keywordC: String? = nil,
        genre: String? = nil,
        neta: String? = nil,
        memo: String? = nil,
        rating: Int? = nil,
        unseen: Bool? = nil,
        bookType: Int? = nil,
        series: String? = nil,
        volume: Double? = nil,
        coverImageName: String? = nil,
        pageDirection: PageDirection? = nil,
        clearSeries: Bool = false,
        clearVolume: Bool = false,
        clearCoverImageName: Bool = false,
        clearPageDirection: Bool = false
    ) {
        self.title = title; self.author = author
        self.keywordA = keywordA; self.keywordB = keywordB; self.keywordC = keywordC
        self.genre = genre; self.neta = neta; self.memo = memo
        self.rating = rating; self.unseen = unseen; self.bookType = bookType
        self.series = series; self.volume = volume
        self.coverImageName = coverImageName
        self.pageDirection = pageDirection
        self.clearSeries = clearSeries
        self.clearVolume = clearVolume
        self.clearCoverImageName = clearCoverImageName
        self.clearPageDirection = clearPageDirection
    }

    public var isEmpty: Bool { self == BookPatch() }
}

public enum BookPatchError: Error, Equatable, Sendable {
    case emptyTitle
}
