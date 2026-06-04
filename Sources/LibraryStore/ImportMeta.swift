// SPDX-License-Identifier: MIT
import Foundation

public struct ImportMeta: Sendable, Equatable {
    public let schemaVersion: Int
    public let importedAt: Date
    public let sourceXMLPath: String
    public let sourceXMLMTime: Date
    public let importerVersion: String
    public let bookCount: Int
    public let skippedCount: Int
    public let notes: String?

    public init(
        schemaVersion: Int,
        importedAt: Date,
        sourceXMLPath: String,
        sourceXMLMTime: Date,
        importerVersion: String,
        bookCount: Int,
        skippedCount: Int,
        notes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.importedAt = importedAt
        self.sourceXMLPath = sourceXMLPath
        self.sourceXMLMTime = sourceXMLMTime
        self.importerVersion = importerVersion
        self.bookCount = bookCount
        self.skippedCount = skippedCount
        self.notes = notes
    }
}
