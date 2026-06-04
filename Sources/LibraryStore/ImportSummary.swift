// SPDX-License-Identifier: MIT
import Foundation

public struct ImportSummary: Sendable {
    public var imported: Int = 0
    public var skipped: [SkippedBook] = []
    public var elapsed: TimeInterval = 0
    public var warnings: [String] = []

    public init() {}
}

public struct SkippedBook: Sendable, Equatable {
    public let id: String
    public let reason: String

    public init(id: String, reason: String) {
        self.id = id
        self.reason = reason
    }
}
