// SPDX-License-Identifier: MIT
import Foundation
import StackroomFormat

public enum FormatToken: String, CaseIterable, Sendable {
    case title
    case author
    case genre
    case keywordA
    case keywordB
    case relation
    case type
    case series
    case volume
    case keywordC

    public init?(raw: String) {
        guard raw.hasPrefix("@") else { return nil }
        let stripped = String(raw.dropFirst())
        guard let token = FormatToken(rawValue: stripped) else { return nil }
        self = token
    }

    /// The textual representation that would appear in a format string.
    public var rawSyntax: String { "@" + rawValue }

    /// Returns the value of the corresponding field on the record, or nil if empty/missing.
    ///
    /// - Parameter bookTypeLabels: Optional override map (bookType Int → label String).
    ///   When a key matches `record.bookType`, the override label is used instead of the
    ///   canonical label. Defaults to empty (canonical labels only). Pass
    ///   `LibrarySettings.bookTypeLabelOverrides` for WYSIWYG filename generation.
    /// - Parameter volumeWidth: `@volume` をゼロ埋めする桁数。既定 2。
    ///   シリーズごとの値は `VolumeWidth.widths(fromMaxVolumes:)` で作る。
    public func value(in record: BookRecord,
                      bookTypeLabels: [Int: String] = [:],
                      volumeWidth: Int = VolumeWidth.minimum) -> String? {
        let raw: String?
        switch self {
        case .title:    raw = record.title
        case .author:   raw = record.author
        case .genre:    raw = record.genre
        case .keywordA: raw = record.keywordA
        case .keywordB: raw = record.keywordB
        case .keywordC: raw = record.keywordC
        case .series:   raw = record.series
        // Stackroom legacy: "Relation" field is stored as `neta` column (Phase 2.4 schema decision)
        case .relation: raw = record.neta
        case .type:
            // Use custom override if provided; fall back to canonical label for in-range types.
            raw = bookTypeLabels[record.bookType] ?? BookTypeLabel.label(for: record.bookType)
        case .volume:
            // 巻数だけは幅に依存するのでここで組み立てて返す（raw を経由しない）。
            guard let v = record.volume, v >= 0 else { return nil }
            return Self.renderVolume(v, width: volumeWidth)
        }
        guard let s = raw, !s.isEmpty else { return nil }
        return s
    }

    /// 巻数の文字列化。整数部を `width` 桁までゼロ埋めし、小数部があれば後ろに付ける。
    /// 7・幅 2 → "07" / 7.5・幅 2 → "07.5" / 120・幅 3 → "120"
    static func renderVolume(_ v: Double, width: Int) -> String {
        let intPart = Int(v.rounded(.towardZero))
        let padded = String(format: "%0\(Swift.max(width, 1))d", intPart)
        let frac = v - Double(intPart)
        if frac == 0 { return padded }
        var s = String(format: "%g", frac)   // "0.5"
        if s.hasPrefix("0") { s.removeFirst() }  // ".5"
        return padded + s
    }
}

/// Stackroom-compatible book_type label mapping (0-5).
/// Used by `FormatToken.type` for forward rendering and reverse lookup.
public enum BookTypeLabel {
    /// 正準ラベル（index = book_type 0..5）。表示の単一ソース。
    public static let canonicalLabels: [String] = [
        "厚い本", "薄い本", "本の一部", "画像セット", "テキスト", "ムービー"
    ]

    static let labels: [Int: String] = Dictionary(
        uniqueKeysWithValues: canonicalLabels.enumerated().map { ($0.offset, $0.element) }
    )

    /// 範囲内なら正準ラベル、範囲外は空文字。
    public static func canonicalLabel(for type: Int) -> String {
        guard canonicalLabels.indices.contains(type) else { return "" }
        return canonicalLabels[type]
    }

    public static func label(for type: Int) -> String? {
        labels[type]
    }
}

public enum FormatSegment: Equatable, Sendable {
    case literal(String)
    case token(FormatToken)
    case bracketGroup(open: Character, body: [FormatSegment], close: Character)
}

public struct FilenameFormat: Equatable, Sendable {
    public let segments: [FormatSegment]

    public enum ParseError: Error, Equatable {
        case unknownToken(String)
        case unclosedBracket(Character)
        case nestedBracket
    }

    public init(raw: String) throws {
        var index = raw.startIndex
        self.segments = try Self.parseSegments(raw, &index, terminator: nil)
    }

    private static func parseSegments(
        _ s: String,
        _ i: inout String.Index,
        terminator: Character?
    ) throws -> [FormatSegment] {
        var segments: [FormatSegment] = []
        var literalBuffer = ""

        func flushLiteral() {
            if !literalBuffer.isEmpty {
                segments.append(.literal(literalBuffer))
                literalBuffer = ""
            }
        }

        while i < s.endIndex {
            let c = s[i]
            if let term = terminator, c == term {
                flushLiteral()
                return segments
            }
            switch c {
            case "@":
                // Read identifier
                let start = i
                i = s.index(after: i)
                var name = ""
                while i < s.endIndex {
                    let ch = s[i]
                    if ch.isLetter || ch.isNumber {
                        name.append(ch)
                        i = s.index(after: i)
                    } else {
                        break
                    }
                }
                let rawToken = String(s[start..<i])
                guard let token = FormatToken(raw: rawToken) else {
                    throw ParseError.unknownToken(rawToken)
                }
                flushLiteral()
                segments.append(.token(token))
            case "[", "(":
                let open = c
                let close: Character = (c == "[") ? "]" : ")"
                if terminator != nil {
                    throw ParseError.nestedBracket
                }
                flushLiteral()
                i = s.index(after: i)
                let body = try parseSegments(s, &i, terminator: close)
                // parseSegments returns only when s[i] == close, or throws unclosedBracket on EOF;
                // both checks below would be unreachable, so simply consume the close.
                i = s.index(after: i)
                segments.append(.bracketGroup(open: open, body: body, close: close))
            default:
                literalBuffer.append(c)
                i = s.index(after: i)
            }
        }

        if let term = terminator {
            // Reached EOF without finding terminator
            throw ParseError.unclosedBracket(term == "]" ? "[" : "(")
        }
        flushLiteral()
        return segments
    }
}
