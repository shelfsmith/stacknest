// SPDX-License-Identifier: MIT
import Foundation
import Observation

/// Tracks bundle URLs currently open in any window. SwiftUI windows register
/// on appear and unregister on disappear; calls to `requestOpen(_:)` indicate
/// whether a window already exists for that URL (caller should focus existing
/// instead of opening a new one).
@MainActor
@Observable
public final class OpenLibraryRegistry {
    public static let shared = OpenLibraryRegistry()

    /// Currently registered bundle URLs (canonicalized via standardizedFileURL).
    private(set) public var openURLs: Set<URL> = []

    private init() {}

    /// Returns true if registration succeeded (URL was not already open).
    /// If false, caller should focus the existing window instead.
    @discardableResult
    public func register(_ url: URL) -> Bool {
        let canonical = url.standardizedFileURL
        let inserted = openURLs.insert(canonical).inserted
        return inserted
    }

    public func unregister(_ url: URL) {
        openURLs.remove(url.standardizedFileURL)
    }

    public func contains(_ url: URL) -> Bool {
        openURLs.contains(url.standardizedFileURL)
    }
}
