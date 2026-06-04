// SPDX-License-Identifier: MIT
import Foundation

/// Represents a `.stacknest` macOS package on disk.
/// Bundle layout:
///   <bundleURL>/Info.plist           — bundle marker (StackNestBundleVersion = 1)
///   <bundleURL>/library.sqlite       — main DB (GRDB)
///   <bundleURL>/Thumbnails/<bookID>/thumbnail.jpg
public struct LibraryBundle: Equatable, Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Path to the SQLite DB inside the bundle.
    public var databaseURL: URL {
        url.appending(path: "library.sqlite")
    }

    /// Path to the Thumbnails directory inside the bundle.
    public var thumbnailsDirectoryURL: URL {
        url.appending(path: "Thumbnails")
    }

    /// Path to the Info.plist marker file.
    public var infoPlistURL: URL {
        url.appending(path: "Info.plist")
    }

    /// Bundle marker payload written into Info.plist.
    public static let bundleVersion: Int = 1
    public static let bundleVersionKey: String = "StackNestBundleVersion"
    public static let bundleIdentifierKey: String = "CFBundleIdentifier"
    public static let bundleIdentifier: String = "app.shelfsmith.stacknest.library"

    /// Validate that the URL points to a structurally-valid bundle.
    /// Throws `LibraryBundleError.notADirectory` etc.
    public func validate() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue else {
            throw LibraryBundleError.notADirectory(url)
        }
        guard fm.fileExists(atPath: infoPlistURL.path(percentEncoded: false)) else {
            throw LibraryBundleError.missingInfoPlist(url)
        }
        guard fm.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
            throw LibraryBundleError.missingDatabase(url)
        }
        // Validate Info.plist payload
        let data = try Data(contentsOf: infoPlistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist[Self.bundleVersionKey] as? Int else {
            throw LibraryBundleError.invalidInfoPlist(url)
        }
        guard version == Self.bundleVersion else {
            throw LibraryBundleError.unsupportedBundleVersion(version)
        }
    }
}

public enum LibraryBundleError: Error, Equatable, Sendable {
    case notADirectory(URL)
    case missingInfoPlist(URL)
    case missingDatabase(URL)
    case invalidInfoPlist(URL)
    case unsupportedBundleVersion(Int)
    case alreadyExists(URL)
    case writeFailed(URL, String)
}
