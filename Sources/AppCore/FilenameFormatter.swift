// SPDX-License-Identifier: MIT
import Foundation
import StackroomFormat

public enum FilenameFormatter {
    /// Renders a BookRecord to a filename (without extension) using the given format.
    /// Empty bracketGroups (whose tokens all evaluate to nil) are omitted entirely.
    /// Trailing/leading whitespace and consecutive whitespace are collapsed.
    public static func format(_ record: BookRecord, with format: FilenameFormat) -> String {
        var result = ""
        for seg in format.segments {
            result += render(seg, record: record)
        }
        return collapseWhitespace(sanitize(result))
    }

    private static func render(_ seg: FormatSegment, record: BookRecord) -> String {
        switch seg {
        case .literal(let s):
            return s
        case .token(let t):
            return t.value(in: record) ?? ""
        case .bracketGroup(let open, let body, let close):
            // Group is omitted iff every token in body resolves to nil
            if bodyHasAnyValue(body, record: record) {
                let inner = body.map { render($0, record: record) }.joined()
                return String(open) + inner + String(close)
            } else {
                return ""
            }
        }
    }

    private static func bodyHasAnyValue(_ segs: [FormatSegment], record: BookRecord) -> Bool {
        for s in segs {
            switch s {
            case .literal:
                continue
            case .token(let t):
                if t.value(in: record) != nil { return true }
            case .bracketGroup(_, let inner, _):
                if bodyHasAnyValue(inner, record: record) { return true }
            }
        }
        return false
    }

    private static func sanitize(_ s: String) -> String {
        // Stackroom-compatible substitutions for filesystem-incompatible characters
        let translations: [Character: Character] = [
            ":": "：",
            "/": "／",
            "\\": "￥",
            "|": "｜"
        ]
        var out = ""
        for ch in s {
            if ch == "\0" { continue }
            if let replacement = translations[ch] {
                out.append(replacement)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    private static func collapseWhitespace(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        // Collapse runs of ASCII space (full-width spaces left untouched intentionally)
        var out = ""
        var lastWasSpace = false
        for ch in trimmed {
            if ch == " " {
                if lastWasSpace { continue }
                out.append(ch)
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    // MARK: - Reverse Parser

    public struct ParseResult: Equatable, Sendable {
        public internal(set) var fields: [FormatToken: String] = [:]
        public internal(set) var matched: Bool = false
    }

    /// Reverse-parses a filename (without extension) into token values using the format.
    /// Returns matched=false if the format's required literals cannot be aligned.
    ///
    /// - Parameter basename: The filename stem WITHOUT its file extension. Callers must strip the
    ///   extension before calling (e.g., `url.deletingPathExtension().lastPathComponent`).
    ///   This function does NOT call `deletingPathExtension` internally, so stems that happen to
    ///   contain a dot (e.g., "Naruto Vol.7") are parsed verbatim without accidental truncation.
    public static func parse(_ basename: String, with format: FilenameFormat) -> ParseResult {
        var result = ParseResult()
        var cursor = basename.startIndex
        let success = consume(format.segments, in: basename, &cursor, into: &result)
        // After consuming all segments, cursor should be at end (or only trailing whitespace)
        let remaining = basename[cursor...].trimmingCharacters(in: .whitespaces)
        result.matched = success && remaining.isEmpty
        return result
    }

    /// Convenience: returns a [token: value] dictionary suitable for filling a BookRecord.
    /// On parse failure, falls back to title=basename (without extension), others nil.
    public static func makeBookFields(
        fromBasename basename: String,
        with format: FilenameFormat
    ) -> [FormatToken: String] {
        let result = parse(basename, with: format)
        if result.matched {
            return result.fields
        }
        // Fallback: extract title from basename (strip extension)
        let stripped = (basename as NSString).deletingPathExtension
        return [.title: stripped]
    }

    /// Recursive consumer. Returns true iff segments matched up to (and including) any required terminator.
    ///
    /// Bracket groups are optional (the forward formatter omits them when their tokens are nil).
    /// Whitespace-only literals that fall between skipped bracket groups are also treated as optional
    /// because the forward formatter collapses consecutive spaces via `collapseWhitespace`.
    ///
    /// Assignment is greedy left-to-right: the first bracketGroup slot in the format that can be
    /// matched at cursor claims the bracket. When the input contains fewer `[...]` groups than the
    /// format has optional bracketGroup slots, the earlier slots win.
    private static func consume(
        _ segments: [FormatSegment],
        in s: String,
        _ cursor: inout String.Index,
        into result: inout ParseResult
    ) -> Bool {
        var idx = 0
        // Track whether the immediately preceding segment was a bracketGroup that was NOT matched
        // (skipped). When true, subsequent whitespace-only literals may be treated as optional,
        // because the forward formatter collapses multiple spaces into one via collapseWhitespace.
        var prevBracketSkipped = false
        // Track whether at least one bracketGroup was successfully matched in this consume pass.
        // When true, whitespace-only literals after a skipped bracketGroup are always optional
        // (the forward formatter's collapseWhitespace already merged them away).
        var anyBracketMatched = false
        while idx < segments.count {
            let seg = segments[idx]
            switch seg {
            case .literal(let lit):
                let range = s.range(of: lit, range: cursor..<s.endIndex)
                if let range = range, range.lowerBound == cursor {
                    cursor = range.upperBound
                    prevBracketSkipped = false
                } else if prevBracketSkipped && anyBracketMatched
                            && lit.trimmingCharacters(in: .whitespaces).isEmpty {
                    // At least one bracketGroup matched earlier, a preceding bracketGroup was
                    // skipped, and this literal is whitespace-only. The forward formatter
                    // collapsed these spaces, so treat the literal as absent here too.
                    // prevBracketSkipped stays true (chain of skipped brackets + whitespace)
                } else if prevBracketSkipped && !anyBracketMatched
                            && lit.trimmingCharacters(in: .whitespaces).isEmpty {
                    // No bracketGroup has matched yet, preceding was skipped, this is
                    // whitespace-only. This covers the case where ALL optional bracketGroups
                    // are absent (e.g., a plain filename like "Naruto Vol.7" against the
                    // Stackroom default format). The forward formatter collapses all the
                    // inter-bracket spaces away, so elide this whitespace literal unconditionally.
                    // This also handles the original narrower case (next is bracketGroup).
                    // prevBracketSkipped stays true.
                } else {
                    // Literal required but not found at cursor — format does not match.
                    return false
                }
            case .token(let token):
                // Look ahead for the next literal/bracketGroup boundary
                let nextBoundary = findNextLiteralAnchor(segments, from: idx + 1, in: s, cursor: cursor)
                let valueRange: Range<String.Index>
                if let anchor = nextBoundary {
                    valueRange = cursor..<anchor.lowerBound
                } else {
                    valueRange = cursor..<s.endIndex
                }
                let value = String(s[valueRange]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    result.fields[token] = value
                }
                cursor = valueRange.upperBound
                prevBracketSkipped = false
            case .bracketGroup(let open, let body, let close):
                // Try to match `open <body> close` at cursor (allowing leading whitespace)
                if let newCursor = tryMatchBracket(
                    open: open, body: body, close: close,
                    in: s, cursor: cursor, into: &result
                ) {
                    cursor = newCursor
                    prevBracketSkipped = false
                    anyBracketMatched = true
                } else {
                    // bracketGroup is optional ⇒ skip without advancing cursor
                    prevBracketSkipped = true
                }
            }
            idx += 1
        }
        return true
    }

    /// Returns true if any of segments[from...] (skipping whitespace-only literals) is a bracketGroup.
    private static func nextSegmentIsBracketGroup(_ segments: [FormatSegment], from startIndex: Int) -> Bool {
        for i in startIndex..<segments.count {
            switch segments[i] {
            case .bracketGroup:
                return true
            case .literal(let lit):
                if lit.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                return false
            case .token:
                return false
            }
        }
        return false
    }

    /// Finds the next literal anchor (literal or bracketGroup-open) starting at segments[startIndex].
    /// Returns the range in `s` where it appears (searching from cursor onward).
    ///
    /// **Note:** If two `.token` segments are adjacent (e.g., `@author@title` with no separator),
    /// the first token will greedily consume to the next anchor or end-of-string. This is a
    /// known limitation — adjacent bare tokens have no way to disambiguate boundaries.
    /// Phase 2.5b assumes the Stackroom-default format style where tokens are always separated
    /// by literals or bracket groups.
    private static func findNextLiteralAnchor(
        _ segments: [FormatSegment],
        from startIndex: Int,
        in s: String,
        cursor: String.Index
    ) -> Range<String.Index>? {
        for i in startIndex..<segments.count {
            switch segments[i] {
            case .literal(let lit):
                return s.range(of: lit, range: cursor..<s.endIndex)
            case .bracketGroup(let open, _, _):
                return s.range(of: String(open), range: cursor..<s.endIndex)
            case .token:
                continue
            }
        }
        return nil
    }

    /// Attempts to match an entire bracketGroup at cursor (allowing leading whitespace).
    /// On success, fills tokens into `result` and returns the index just past the close character.
    /// On failure (group absent), returns nil.
    private static func tryMatchBracket(
        open: Character,
        body: [FormatSegment],
        close: Character,
        in s: String,
        cursor: String.Index,
        into result: inout ParseResult
    ) -> String.Index? {
        // Skip leading whitespace
        var c = cursor
        // ASCII space only (consistent with forward path's collapseWhitespace which also
        // preserves full-width spaces intentionally per Stackroom convention).
        while c < s.endIndex, s[c] == " " { c = s.index(after: c) }
        guard c < s.endIndex, s[c] == open else { return nil }
        // Move past open
        let inner = s.index(after: c)
        // Find matching close
        guard let closeRange = s.range(of: String(close), range: inner..<s.endIndex) else {
            return nil
        }
        let innerEnd = closeRange.lowerBound
        // Extract the bounded inner content as a separate String so that
        // consume() cannot accidentally look past the closing bracket.
        let innerContent = String(s[inner..<innerEnd])
        var innerCursor = innerContent.startIndex
        var localResult = result
        let ok = consume(body, in: innerContent, &innerCursor, into: &localResult)
        if !ok { return nil }
        // After consume, innerCursor should be at end (or only trailing whitespace)
        let trailing = innerContent[innerCursor...].trimmingCharacters(in: .whitespaces)
        if !trailing.isEmpty { return nil }
        result = localResult
        // Move past close character in the outer string
        return closeRange.upperBound
    }
}
