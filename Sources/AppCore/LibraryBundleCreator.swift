// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import StackroomFormat

/// Creates new `.stacknest` bundles, either empty (for "Create new library")
/// or by importing a Stackroom Library.xml (for "Import from Stackroom XML").
public enum LibraryBundleCreator {

    /// Creates an empty bundle at the given URL: directory + Info.plist + empty Thumbnails/
    /// + an empty SQLite DB with all migrations applied. Throws if the URL already exists
    /// (caller must ensure NSSavePanel returned a non-existent destination).
    @discardableResult
    public static func createEmpty(at url: URL) throws -> LibraryBundle {
        let fm = FileManager.default
        let bundle = LibraryBundle(url: url)

        if fm.fileExists(atPath: url.path(percentEncoded: false)) {
            throw LibraryBundleError.alreadyExists(url)
        }

        // Create directory + Thumbnails subdir
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.thumbnailsDirectoryURL, withIntermediateDirectories: true)

        // Write Info.plist
        let plist: [String: Any] = [
            LibraryBundle.bundleVersionKey: LibraryBundle.bundleVersion,
            LibraryBundle.bundleIdentifierKey: LibraryBundle.bundleIdentifier
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.infoPlistURL)

        // Create empty DB and run migrations through v8
        let db = try Database.openFile(at: bundle.databaseURL, mode: .createOrReplace)
        try db.migrate()
        _ = try db.ensureFavoritesShelf()
        db.close()

        return bundle
    }

    /// Creates a new bundle by importing a Stackroom Library.xml.
    /// Creates the bundle structure, parses the XML, imports books into the database,
    /// and copies thumbnails from the source directory.
    @discardableResult
    public static func createFromStackroomXML(
        xmlURL: URL,
        into bundleURL: URL,
        progress: ProgressReporter? = nil
    ) throws -> LibraryBundle {
        // Create the empty bundle first
        let bundle = try createEmpty(at: bundleURL)

        // Parse the Stackroom Library.xml using PropertyListDecoder
        let xmlData = try Data(contentsOf: xmlURL)
        let document = try PropertyListDecoder().decode(LibraryDocument.self, from: xmlData)

        // Open the bundle's database for import
        let db = try Database.openExisting(at: bundle.databaseURL)
        defer { db.close() }

        // Import books and metadata (inject FilenameParser for series/volume auto-completion)
        let importer = LibraryImporter(database: db, seriesVolumeParser: { title, filename in
            let p = FilenameParser.parse(title: title, filename: filename)
            return (p.series, p.volume)
        })
        let xmlMTime = (try? FileManager.default.attributesOfItem(atPath: xmlURL.path(percentEncoded: false))[.modificationDate] as? Date) ?? Date()

        _ = try importer.run(
            document: document,
            sourceURL: xmlURL,
            sourceMTime: xmlMTime,
            progress: progress
        )

        // Copy thumbnails from the source directory
        try copyThumbnailsFromStackroom(xmlURL: xmlURL, into: bundle)

        return bundle
    }

    /// Walks the directory containing xmlURL, finds `<bookID>/thumbnail.jpg` siblings,
    /// and copies them to the bundle's Thumbnails directory.
    /// Prefers the <xml-basename-without-extension> subdirectory; falls back to the XML's parent directory.
    private static func copyThumbnailsFromStackroom(
        xmlURL: URL,
        into bundle: LibraryBundle
    ) throws {
        let fm = FileManager.default
        let xmlParent = xmlURL.deletingLastPathComponent()
        let xmlBaseName = xmlURL.deletingPathExtension().lastPathComponent
        let preferredSourceDir = xmlParent.appendingPathComponent(xmlBaseName)

        let sourceDir: URL
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: preferredSourceDir.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue {
            sourceDir = preferredSourceDir
        } else {
            sourceDir = xmlParent
        }

        let targetDir = bundle.thumbnailsDirectoryURL

        guard let items = try? fm.contentsOfDirectory(atPath: sourceDir.path(percentEncoded: false)) else {
            return // Source directory doesn't exist or is unreadable; no thumbnails to copy
        }

        for item in items {
            guard Int(item) != nil else { continue }  // bookID dirs only
            let itemPath = sourceDir.appendingPathComponent(item)
            let thumbPath = itemPath.appendingPathComponent("thumbnail.jpg")

            // Check if this is a directory with a thumbnail.jpg file
            var entryIsDir: ObjCBool = false
            guard fm.fileExists(atPath: itemPath.path(percentEncoded: false), isDirectory: &entryIsDir),
                  entryIsDir.boolValue,
                  fm.fileExists(atPath: thumbPath.path(percentEncoded: false)) else {
                continue
            }

            // Copy the thumbnail to the bundle's Thumbnails directory
            let destPath = targetDir.appendingPathComponent(item).appendingPathComponent("thumbnail.jpg")
            try fm.createDirectory(at: destPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: thumbPath, to: destPath)
        }
    }
}
