// SPDX-License-Identifier: MIT
import Foundation

public enum ImportError: Error, LocalizedError, Equatable {
    case xmlNotFound(URL)
    case xmlNotReadable(URL)
    case invalidPlist(String)
    case dbExistsWithoutForce(URL)
    case dbNotFound(URL)
    case dbWriteFailure(String)
    case schemaMigrationFailure(String)
    case databaseNotOpen

    public var errorDescription: String? {
        switch self {
        case .xmlNotFound(let url):           return "XML not found: \(url.path)"
        case .xmlNotReadable(let url):        return "XML not readable: \(url.path)"
        case .invalidPlist(let detail):       return "Invalid plist: \(detail)"
        case .dbExistsWithoutForce(let url):  return "Output database already exists at \(url.path). Use --force to delete and re-import."
        case .dbNotFound(let url):            return "Database not found at \(url.path)."
        case .dbWriteFailure(let detail):     return "Database write failure: \(detail)"
        case .schemaMigrationFailure(let d):  return "Schema migration failure: \(d)"
        case .databaseNotOpen:               return "Database is not open."
        }
    }
}
