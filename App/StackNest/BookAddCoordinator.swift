// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore

/// GUI からの「ファイルを追加」入口。BookImporter（headless コア）への薄いラッパ。
@MainActor
public final class BookAddCoordinator {
    public typealias AddResult = BookImporter.ImportResult
    private let importer: BookImporter
    private let database: Database

    public init(database: Database, bundleURL: URL, format: FilenameFormat) {
        self.database = database
        self.importer = BookImporter(database: database, bundleURL: bundleURL, format: format)
    }

    public func add(urls: [URL]) async -> AddResult {
        await importer.add(
            urls: urls,
            autoClassifyEnabled: ImportDefaults.effectiveAutoClassify(db: database),
            thickThreshold: ImportDefaults.effectiveThickThreshold(db: database))
    }
}
