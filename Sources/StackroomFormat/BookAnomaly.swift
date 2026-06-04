// SPDX-License-Identifier: MIT
import Foundation

public enum BookAnomaly: Error, LocalizedError, Equatable, Sendable {
    case dictKeyNotInteger(rawKey: String)
    case missingRequiredField(name: String)
    case malformedDate(field: String)
    case dateOutOfRange(field: String, value: Date)
    case malformedBookEntry(rawKey: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .dictKeyNotInteger(let raw):
            return "Books dictionary key '\(raw)' is not an integer"
        case .missingRequiredField(let name):
            return "Required field '\(name)' is missing"
        case .malformedDate(let field):
            return "Field '\(field)' is not a valid date"
        case .dateOutOfRange(let field, let value):
            return "Field '\(field)' has out-of-range date value \(value)"
        case .malformedBookEntry(let raw, let underlying):
            return "Books entry '\(raw)' could not be decoded: \(underlying)"
        }
    }
}
