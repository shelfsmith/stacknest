// SPDX-License-Identifier: MIT
import Foundation

/// One Stackroom library item ("book"). Spec 1 builds this struct field-by-field.
public struct BookRecord: Codable, Sendable {
    public let id: Int
    public let title: String
    public let author: String?
    public let genre: String?
    public let path: String?
    public let coverImagePath: String
    public let coverImageName: String?
    public let dateAdded: Date
    public let playDate: Date?
    public let bookType: Int
    public let fileType: Int
    public let pages: Int?
    public let myRate: Int          // 0..5 clamped
    public let unseen: Bool         // bool/int normalized
    public let keywordA: String?
    public let keywordB: String?
    public let keywordC: String?
    public let neta: String?
    public let series: String?
    public let volume: Double?

    public init(
        id: Int,
        title: String,
        author: String? = nil,
        genre: String? = nil,
        path: String? = nil,
        coverImagePath: String = "",
        coverImageName: String? = nil,
        dateAdded: Date,
        playDate: Date? = nil,
        bookType: Int = 0,
        fileType: Int = 2,
        pages: Int? = nil,
        myRate: Int = 0,
        unseen: Bool = true,
        keywordA: String? = nil,
        keywordB: String? = nil,
        keywordC: String? = nil,
        neta: String? = nil,
        series: String? = nil,
        volume: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.genre = genre
        self.path = path
        self.coverImagePath = coverImagePath
        self.coverImageName = coverImageName
        self.dateAdded = dateAdded
        self.playDate = playDate
        self.bookType = bookType
        self.fileType = fileType
        self.pages = pages
        self.myRate = max(0, min(5, myRate))
        self.unseen = unseen
        self.keywordA = keywordA
        self.keywordB = keywordB
        self.keywordC = keywordC
        self.neta = neta
        self.series = series
        self.volume = volume
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id              = try c.decode(Int.self, forKey: .id)
        self.title           = try c.decode(String.self, forKey: .title)
        self.author          = try c.decodeIfPresent(String.self, forKey: .author)
        self.genre           = try c.decodeIfPresent(String.self, forKey: .genre)
        // G49: `Path` 欠落の復元は取り込み層（LibraryImporter＋StackroomPathRecovery）が行う。
        // ここは XML の忠実な写しに保つ（復元したことを利用者に報告する必要があるため）。
        self.path            = try c.decodeIfPresent(String.self, forKey: .path)
        self.coverImagePath  = try c.decode(String.self, forKey: .coverImagePath)
        self.coverImageName  = try c.decodeIfPresent(String.self, forKey: .coverImageName)
        self.dateAdded       = try c.decode(Date.self, forKey: .dateAdded)
        self.playDate        = try c.decodeIfPresent(Date.self, forKey: .playDate)
        self.bookType        = try c.decode(Int.self, forKey: .bookType)
        self.fileType        = try c.decode(Int.self, forKey: .fileType)
        self.pages           = try c.decodeIfPresent(Int.self, forKey: .pages)
        let rawRate          = try c.decodeIfPresent(Int.self, forKey: .myRate) ?? 0
        self.myRate          = max(0, min(5, rawRate))

        // Unseen normalization: bool / int / missing
        if let asBool = try? c.decodeIfPresent(Bool.self, forKey: .unseen) {
            self.unseen = asBool ?? false
        } else if let asInt = try? c.decodeIfPresent(Int.self, forKey: .unseen) {
            self.unseen = (asInt ?? 0) >= 1
        } else {
            self.unseen = false
        }

        self.keywordA = try c.decodeIfPresent(String.self, forKey: .keywordA)
        self.keywordB = try c.decodeIfPresent(String.self, forKey: .keywordB)
        self.keywordC = try c.decodeIfPresent(String.self, forKey: .keywordC)
        self.neta     = try c.decodeIfPresent(String.self, forKey: .neta)
        self.series   = try c.decodeIfPresent(String.self, forKey: .series)
        self.volume   = try c.decodeIfPresent(Double.self, forKey: .volume)
    }

    public enum CodingKeys: String, CodingKey {
        case id              = "ID"
        case title           = "Title"
        case author          = "Author"
        case genre           = "Genre"
        case path            = "Path"
        case coverImagePath  = "Cover Image Path"
        case coverImageName  = "Cover Image Name"
        case dateAdded       = "Date Added"
        case playDate        = "Play Date"
        case bookType        = "Book Type"
        case fileType        = "File Type"
        case pages           = "Pages"
        case myRate          = "My Rate"
        case unseen          = "Unseen"
        case keywordA        = "Keyword A"
        case keywordB        = "Keyword B"
        case keywordC        = "Keyword C"
        case neta            = "Neta"
        case series          = "Series"
        case volume          = "Volume"
    }
}
