// SPDX-License-Identifier: MIT
import Foundation

public struct PlaylistConditions: Codable, Sendable {
    public let dateCondition: DateCondition?
    public let rateCondition: RateCondition?
    public let keywordCondition: KeywordCondition?

    public enum CodingKeys: String, CodingKey {
        case dateCondition    = "Date Condition"
        case rateCondition    = "Rate Condition"
        case keywordCondition = "Keyword Condition"
    }
}

public struct DateCondition: Codable, Sendable {
    public let condition: String
    public let key: Int
    public let option: Int

    public enum CodingKeys: String, CodingKey {
        case condition = "Condition"
        case key       = "Key"
        case option    = "Option"
    }
}

public struct RateCondition: Codable, Sendable {
    public let value: Int
    public let option: Int

    public enum CodingKeys: String, CodingKey {
        case value  = "Value"
        case option = "Option"
    }
}

public struct KeywordCondition: Codable, Sendable {
    public let value: String
    public let option: Int

    public enum CodingKeys: String, CodingKey {
        case value  = "Value"
        case option = "Option"
    }
}
