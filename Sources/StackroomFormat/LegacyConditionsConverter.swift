// SPDX-License-Identifier: MIT
import Foundation

/// 旧 `PlaylistConditions`（Date/Rate/Keyword の固定トリプル）を新 `SmartShelfConditions` に
/// 変換する純関数。combinator は旧仕様の暗黙 AND に合わせ `.all`。
public enum LegacyConditionsConverter {
    /// 旧 DateCondition.condition が最終閲覧日を指すときの値（実データで確認済）。
    private static let playDateConditionValue = "Play Date"

    public static func convert(_ legacy: PlaylistConditions) -> SmartShelfConditions {
        var rules: [SmartShelfRule] = []

        if let d = legacy.dateCondition {
            let field: SmartShelfRule.Field = (d.condition == Self.playDateConditionValue) ? .playDate : .dateAdded
            let op: SmartShelfRule.Operator = (d.option == 1) ? .olderThan : .within
            rules.append(SmartShelfRule(id: UUID(), field: field, op: op, value: .days(d.key)))
        }
        if let rate = legacy.rateCondition {
            let op: SmartShelfRule.Operator
            switch rate.option {
            case 1: op = .lte
            case 2: op = .eq
            default: op = .gte   // 0 および未知 Option のフォールバック
            }
            rules.append(SmartShelfRule(id: UUID(), field: .rating, op: op, value: .int(rate.value)))
        }
        if let kw = legacy.keywordCondition {
            // KeywordCondition.option の意味は実例が無く未確定（全実例 option=0）。対象フィールドも
            // 不明なため keywordA + .contains の安全側にフォールバック。実例出現時に Phase 2.7 で精緻化。
            rules.append(SmartShelfRule(id: UUID(), field: .keywordA, op: .contains, value: .text(kw.value)))
        }

        return SmartShelfConditions(match: .all, rules: rules)
    }
}
