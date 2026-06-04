// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import StackroomFormat

/// Apple Mail ルール風のスマートシェルフ条件エディタ。
struct SmartShelfEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var match: SmartShelfConditions.MatchMode
    @State private var rules: [SmartShelfRule]
    let settings: LibrarySettings
    let onSave: (String, SmartShelfConditions) -> Void

    init(settings: LibrarySettings,
         initialName: String = "",
         initialConditions: SmartShelfConditions = SmartShelfConditions(
            match: .all,
            rules: [SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text(""))]),
         onSave: @escaping (String, SmartShelfConditions) -> Void) {
        self.settings = settings
        _name = State(initialValue: initialName)
        _match = State(initialValue: initialConditions.match)
        _rules = State(initialValue: initialConditions.rules.isEmpty
            ? [SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text(""))]
            : initialConditions.rules)
        self.onSave = onSave
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, !rules.isEmpty else { return false }
        // テキスト系ルールは空値を許さない（空の contains は全件マッチになり混乱を招くため）
        for rule in rules where rule.field.isText {
            if rule.value.asText.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("スマートシェルフ").font(.headline)
            HStack {
                Text("名前:")
                TextField("名前", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("次の条件を")
                Picker("", selection: $match) {
                    Text("すべて").tag(SmartShelfConditions.MatchMode.all)
                    Text("いずれか").tag(SmartShelfConditions.MatchMode.any)
                }.fixedSize()
                Text("満たす")
            }
            ForEach($rules) { $rule in
                SmartShelfRuleRow(rule: $rule, settings: settings, onRemove: {
                    rules.removeAll { $0.id == rule.id }
                }, canRemove: rules.count > 1)
            }
            Button {
                rules.append(SmartShelfRule(id: UUID(), field: .genre, op: .contains, value: .text("")))
            } label: { Image(systemName: "plus") }
            .buttonStyle(.borderless)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") {
                    onSave(name, SmartShelfConditions(match: match, rules: rules))
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(20)
        .frame(minWidth: 480)
    }
}

/// 1 ルール行: フィールド → operator → 値。
private struct SmartShelfRuleRow: View {
    @Binding var rule: SmartShelfRule
    let settings: LibrarySettings
    let onRemove: () -> Void
    let canRemove: Bool

    var body: some View {
        HStack {
            Picker("", selection: $rule.field) {
                ForEach(SmartShelfRule.Field.allCases, id: \.self) { f in
                    Text(label(for: f)).tag(f)
                }
            }.fixedSize()
            .onChange(of: rule.field) { _, newField in
                // 同じ型のフィールド間移動では op/value を保持し、型が変わるときだけリセット
                if !operators(for: newField).contains(rule.op) {
                    rule.op = defaultOp(for: newField)
                }
                if !valueKindMatches(rule.value, defaultValue(for: newField)) {
                    rule.value = defaultValue(for: newField)
                }
            }

            Picker("", selection: opBinding) {
                ForEach(operators(for: rule.field), id: \.self) { op in
                    Text(label(for: op)).tag(op)
                }
            }.fixedSize()

            valueEditor

            if canRemove {
                Button { onRemove() } label: { Image(systemName: "minus") }
                    .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        if rule.field == .unseen {
            EmptyView()
        } else if rule.field.isDate {
            HStack(spacing: 4) {
                TextField("日数", value: daysBinding, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                Text("日")
            }
        } else if rule.field == .rating {
            Picker("", selection: intBinding) {
                ForEach(0...5, id: \.self) { Text("★\($0)").tag($0) }
            }.fixedSize()
        } else if rule.field == .bookType || rule.field == .pages {
            TextField("値", value: intBinding, format: .number).frame(width: 80).textFieldStyle(.roundedBorder)
        } else {
            TextField("値", text: textBinding).textFieldStyle(.roundedBorder)
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { rule.value.asText }, set: { rule.value = .text($0) })
    }
    private var intBinding: Binding<Int> {
        Binding(get: { rule.value.asInt }, set: { rule.value = .int($0) })
    }
    private var daysBinding: Binding<Int> {
        Binding(get: { rule.value.asDays }, set: { rule.value = .days($0) })
    }

    private func operators(for field: SmartShelfRule.Field) -> [SmartShelfRule.Operator] {
        if field.isText { return [.contains, .equals, .startsWith, .endsWith] }
        if field.isDate { return [.within, .olderThan] }
        if field == .unseen { return [.isUnread, .isRead] }
        return [.gte, .lte, .eq]
    }
    private func defaultOp(for field: SmartShelfRule.Field) -> SmartShelfRule.Operator {
        operators(for: field).first ?? .contains
    }
    private func defaultValue(for field: SmartShelfRule.Field) -> RuleValue {
        if field.isText { return .text("") }
        if field.isDate { return .days(30) }
        if field == .unseen { return .int(0) }
        return .int(0)
    }

    private func valueKindMatches(_ a: RuleValue, _ b: RuleValue) -> Bool {
        switch (a, b) {
        case (.text, .text), (.int, .int), (.days, .days): return true
        default: return false
        }
    }

    /// op が現フィールドの許可リストに無い場合は既定にフォールバックする自己補正 Binding。
    private var opBinding: Binding<SmartShelfRule.Operator> {
        Binding(
            get: {
                let allowed = operators(for: rule.field)
                return allowed.contains(rule.op) ? rule.op : (allowed.first ?? rule.op)
            },
            set: { rule.op = $0 }
        )
    }

    private func label(for f: SmartShelfRule.Field) -> String {
        switch f {
        case .title: return "タイトル"; case .author: return "作者"
        case .genre: return settings.label(for: .genre)
        case .series: return "シリーズ"
        case .neta: return settings.label(for: .neta)
        case .keywordA: return settings.label(for: .keywordA)
        case .keywordB: return settings.label(for: .keywordB)
        case .keywordC: return settings.stampLabel(for: .keywordC)
        case .memo: return "メモ"
        case .bookType: return "種類"; case .rating: return "評価"; case .unseen: return "未読"
        case .pages: return "ページ数"; case .dateAdded: return "追加日"; case .playDate: return "最終閲覧日"
        }
    }
    // 注: .equals(テキスト等価) と .eq(数値等価) は異なるフィールド型で使われ同時に現れないため、同じ日本語ラベルでよい。
    private func label(for op: SmartShelfRule.Operator) -> String {
        switch op {
        case .equals: return "が次と等しい"; case .contains: return "を含む"
        case .startsWith: return "で始まる"; case .endsWith: return "で終わる"
        case .eq: return "が次と等しい"; case .gte: return "以上"; case .lte: return "以下"
        case .within: return "以内"; case .olderThan: return "より前"
        case .isUnread: return "である"; case .isRead: return "ではない"
        }
    }
}
