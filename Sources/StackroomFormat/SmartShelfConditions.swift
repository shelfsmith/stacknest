// SPDX-License-Identifier: MIT
import Foundation

/// 動的フィルタ条件のセット。`playlist.conditions` BLOB に JSON で永続化される。
public struct SmartShelfConditions: Codable, Sendable, Equatable {
    public var version: Int
    public var match: MatchMode
    public var rules: [SmartShelfRule]

    public enum MatchMode: String, Codable, Sendable { case all, any }

    public init(version: Int = 1, match: MatchMode, rules: [SmartShelfRule]) {
        self.version = version
        self.match = match
        self.rules = rules
    }
}

public struct SmartShelfRule: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var field: Field
    /// マッチ演算子（Operator: テキスト/数値/日付/unseen の各種）。
    public var op: Operator
    public var value: RuleValue

    public init(id: UUID, field: Field, op: Operator, value: RuleValue) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }

    public enum Field: String, Codable, Sendable, CaseIterable {
        case title, author, genre, series, neta
        case keywordA, keywordB, keywordC, memo
        case bookType, rating, unseen, pages
        case dateAdded, playDate

        /// このフィールドがテキスト型か（文字列マッチ operator を使うか）。
        public var isText: Bool {
            switch self {
            case .title, .author, .genre, .series, .neta,
                 .keywordA, .keywordB, .keywordC, .memo: return true
            default: return false
            }
        }
        public var isDate: Bool { self == .dateAdded || self == .playDate }
    }

    public enum Operator: String, Codable, Sendable {
        case equals, contains, startsWith, endsWith   // テキスト
        case eq, gte, lte                             // 数値
        case within, olderThan                        // 日付
        case isUnread, isRead                         // unseen
    }
}

/// ルールの値。フィールド型に応じて text / int / days のいずれか。
public enum RuleValue: Codable, Sendable, Equatable {
    case text(String)
    case int(Int)
    case days(Int)

    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text": self = .text(try c.decode(String.self, forKey: .value))
        case "int":  self = .int(try c.decode(Int.self, forKey: .value))
        case "days": self = .days(try c.decode(Int.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "unknown RuleValue kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s): try c.encode("text", forKey: .kind); try c.encode(s, forKey: .value)
        case .int(let i):  try c.encode("int",  forKey: .kind); try c.encode(i, forKey: .value)
        case .days(let d): try c.encode("days", forKey: .kind); try c.encode(d, forKey: .value)
        }
    }

    /// テキスト系 operator 用。非 text なら空文字。
    public var asText: String {
        guard case .text(let s) = self else { return "" }
        return s
    }
    /// 数値系 operator 用。int / days を Int として返す。
    public var asInt: Int {
        switch self {
        case .int(let i): return i
        case .days(let d): return d
        case .text(let s): return Int(s) ?? 0
        }
    }
    /// 日付系 operator 用（日数）。
    public var asDays: Int {
        switch self {
        case .days(let d): return d
        case .int(let i): return i
        case .text(let s): return Int(s) ?? 0
        }
    }
}
