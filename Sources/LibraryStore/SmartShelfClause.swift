// SPDX-License-Identifier: MIT
import GRDB
import Foundation
import StackroomFormat

extension Database {
    /// `SmartShelfConditions` を WHERE 句断片に変換する。戻り値 `whereSQL` は
    /// 先頭 `" AND "` 付き（`buildFilterClause` と同規約）。空ルールは `" AND 0"`（マッチ 0 件）。
    /// `now` は日付条件の cutoff 計算用（テスト決定性のため注入可能）。
    public static func buildSmartShelfClause(
        _ conditions: SmartShelfConditions,
        now: Date = Date()
    ) -> (whereSQL: String, args: [DatabaseValueConvertible]) {
        guard !conditions.rules.isEmpty else { return (" AND 0", []) }

        var fragments: [String] = []
        var args: [DatabaseValueConvertible] = []

        for r in conditions.rules {
            let (frag, fragArgs) = clauseForRule(r, now: now)
            fragments.append(frag)
            args.append(contentsOf: fragArgs)
        }

        let joiner = (conditions.match == .all) ? " AND " : " OR "
        let whereSQL = " AND (" + fragments.joined(separator: joiner) + ")"
        return (whereSQL, args)
    }

    /// scope が `.smartShelf` のとき conditions を解決して WHERE 句に変換する。
    /// それ以外は `("", [])`。decode/読み取り失敗時は空ルール（マッチ 0 件）に安全側フォールバック。
    /// TODO: decode 失敗を将来ログ出力し、空シェルフと corrupt を区別できるようにする。
    func smartClauseForScope(
        _ scope: SidebarScope
    ) -> (whereSQL: String, args: [DatabaseValueConvertible]) {
        guard case .smartShelf(let pid) = scope else { return ("", []) }
        let conditions = (try? fetchSmartShelfConditions(id: pid))
            ?? SmartShelfConditions(match: .all, rules: [])
        return Self.buildSmartShelfClause(conditions)
    }

    private static func clauseForRule(
        _ r: SmartShelfRule, now: Date
    ) -> (String, [DatabaseValueConvertible]) {
        let col = columnName(for: r.field)

        if r.field.isText {
            switch r.op {
            case .contains:
                return ("\(col) LIKE ? ESCAPE '\\'", ["%\(escapeLikePattern(r.value.asText))%"])
            case .startsWith:
                return ("\(col) LIKE ? ESCAPE '\\'", ["\(escapeLikePattern(r.value.asText))%"])
            case .endsWith:
                return ("\(col) LIKE ? ESCAPE '\\'", ["%\(escapeLikePattern(r.value.asText))"])
            case .equals:
                let (sql, vals) = multiValueClauseForOneValue(column: col, value: r.value.asText)
                return (sql, vals.map { $0 as DatabaseValueConvertible })
            default:
                return ("0", [])   // 不正な組合せ（エディタでガード済）はマッチ 0
            }
        }

        if r.field.isDate {
            let cutoff = now.timeIntervalSince1970 - Double(r.value.asDays) * Self.secondsPerDay
            switch r.op {
            case .within:    return ("\(col) >= ?", [cutoff])
            case .olderThan: return ("\(col) < ?", [cutoff])
            default:         return ("0", [])
            }
        }

        if r.field == .unseen {
            switch r.op {
            case .isUnread: return ("\(col) = 1", [])
            case .isRead:   return ("\(col) = 0", [])
            default:        return ("0", [])
            }
        }

        // numeric: rating / pages / bookType
        switch r.op {
        case .eq:  return ("\(col) = ?",  [r.value.asInt])
        case .gte: return ("\(col) >= ?", [r.value.asInt])
        case .lte: return ("\(col) <= ?", [r.value.asInt])
        default:   return ("0", [])
        }
    }

    private static func columnName(for field: SmartShelfRule.Field) -> String {
        switch field {
        case .title:     return "b.title"
        case .author:    return "b.author"
        case .genre:     return "b.genre"
        case .series:    return "b.series"
        case .neta:      return "b.neta"
        case .keywordA:  return "b.keyword_a"
        case .keywordB:  return "b.keyword_b"
        case .keywordC:  return "b.keyword_c"
        case .memo:      return "b.memo"
        case .bookType:  return "b.book_type"
        case .rating:    return "b.rating"
        case .unseen:    return "b.unseen"
        case .pages:     return "b.pages"
        case .dateAdded: return "b.date_added"
        case .playDate:  return "b.play_date"
        }
    }
}
