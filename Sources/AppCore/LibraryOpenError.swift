// SPDX-License-Identifier: MIT
import Foundation

/// User-facing errors when opening a library, carrying localized (Japanese) descriptions
/// so the UI shows a clear message instead of a raw engine error.
public enum LibraryOpenError: LocalizedError, Equatable, Sendable {
    /// The library cannot be written: Finder "Locked" (user-immutable), a read-only
    /// volume, or missing write permission. Migrations require a writable DB, so the
    /// library cannot be opened.
    case readOnly(URL)

    public var errorDescription: String? {
        switch self {
        case .readOnly:
            return "このライブラリは読み取り専用のため開けません。Finder の「ロック」を解除するか、書き込み可能な場所にコピーしてからお試しください。"
        }
    }
}
