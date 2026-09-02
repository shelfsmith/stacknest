// SPDX-License-Identifier: MIT
import Foundation

public enum EPUBReadingDirection: String, Sendable, Equatable {
    case ltr, rtl, unknown
}

public struct EPUBBookInfo: Sendable, Equatable {
    public let title: String?
    public let author: String?
    public let language: String?
    public let readingDirection: EPUBReadingDirection
    public init(title: String?, author: String?, language: String?, readingDirection: EPUBReadingDirection) {
        self.title = title; self.author = author; self.language = language; self.readingDirection = readingDirection
    }
}
