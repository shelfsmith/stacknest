// SPDX-License-Identifier: MIT
import AppCore
import ArgumentParser
import Foundation
import LibraryStore
import StackroomFormat

public struct ImportCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a Stackroom Library.xml into a SQLite database."
    )

    @Option(help: "Path to Stackroom Library.xml")
    public var xml: String

    @Option(help: "Path to output SQLite database")
    public var out: String

    @Flag(help: "Delete existing output DB before importing")
    public var force: Bool = false

    @Flag(help: "Suppress progress output")
    public var quiet: Bool = false

    public init() {}

    public func run() throws {
        let xmlURL = URL(fileURLWithPath: xml)
        guard FileManager.default.fileExists(atPath: xmlURL.path) else {
            throw ImportError.xmlNotFound(xmlURL)
        }
        let outURL = URL(fileURLWithPath: out)

        let mode: OpenMode = force ? .createOrReplace : .createOrFail
        let db = try Database.openFile(at: outURL, mode: mode)
        defer { db.close() }
        try db.migrate()

        let data = try Data(contentsOf: xmlURL)
        let doc: LibraryDocument
        do {
            doc = try PropertyListDecoder().decode(LibraryDocument.self, from: data)
        } catch {
            throw ImportError.invalidPlist(String(describing: error))
        }

        let xmlMTime = (try? FileManager.default.attributesOfItem(atPath: xmlURL.path)[.modificationDate] as? Date) ?? Date()
        // Inject FilenameParser so the importer fills series/volume for records that have nil values from XML.
        let importer = LibraryImporter(database: db, seriesVolumeParser: { title, filename in
            let parsed = FilenameParser.parse(title: title, filename: filename)
            return (series: parsed.series, volume: parsed.volume)
        })
        let reporter: ProgressReporter? = quiet ? nil : CLIProgressReporter()
        let summary = try importer.run(document: doc, sourceURL: xmlURL, sourceMTime: xmlMTime, progress: reporter)

        if !quiet {
            print("Imported \(summary.imported) books in \(String(format: "%.2f", summary.elapsed))s, skipped \(summary.skipped.count)")
        }
        if summary.skipped.count > 0 {
            throw ExitCode(1)
        }
    }
}

final class CLIProgressReporter: ProgressReporter, @unchecked Sendable {
    private var lastPercent: Int = -1

    func reportProgress(processed: Int, total: Int) {
        guard total > 0 else { return }
        let percent = Int(Double(processed) / Double(total) * 100)
        if percent != lastPercent {
            lastPercent = percent
            FileHandle.standardError.write(Data("\rImporting... \(percent)% (\(processed)/\(total))".utf8))
            if processed == total {
                FileHandle.standardError.write(Data("\n".utf8))
            }
        }
    }
}
