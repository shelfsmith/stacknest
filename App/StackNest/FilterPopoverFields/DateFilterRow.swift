// SPDX-License-Identifier: MIT
import SwiftUI
import LibraryStore

/// Filter popover の日付範囲行。
/// label = "登録日" or "読んだ日"。range は対応する FilterState のプロパティへの Binding。
/// 行頭の Toggle (チェックボックス) で active/inactive 切替。
/// 並び順はロケール依存:
/// - 日本語 (postposition): [N] 日 [以内/以前]
/// - 英語等 (preposition):  [within/older than] [N] days
struct DateFilterRow: View {
    let label: String
    @Binding var range: FilterState.DateRangeCondition?
    @State private var localDays: Int = 7
    @State private var localDirection: FilterState.DateRangeCondition.Direction = .within
    @Environment(\.locale) private var locale

    /// ja / yue / wuu (中国語)・ko 等の postpositional CJK 圏は日本語型レイアウト。
    /// 他は preposition 型 (英語準拠)。
    private var usesPostpositionalLayout: Bool {
        guard let code = locale.language.languageCode?.identifier else { return false }
        return ["ja", "ko", "zh"].contains(code)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { range != nil },
            set: { newValue in
                if newValue {
                    range = .init(direction: localDirection, days: localDays)
                } else {
                    range = nil
                }
            }
        )
    }

    private var directionBinding: Binding<FilterState.DateRangeCondition.Direction> {
        Binding(
            get: { range?.direction ?? localDirection },
            set: { newDirection in
                localDirection = newDirection
                if let r = range {
                    range = .init(direction: newDirection, days: r.days)
                }
            }
        )
    }

    private var daysBinding: Binding<Int> {
        Binding(
            get: { range?.days ?? localDays },
            set: { newDays in
                let clamped = max(1, newDays)
                localDays = clamped
                if let r = range {
                    range = .init(direction: r.direction, days: clamped)
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: enabledBinding)
                .labelsHidden()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)

            if usesPostpositionalLayout {
                // [N] 日 [以内]
                daysField
                unitText
                directionPicker
            } else {
                // [within] [N] days
                directionPicker
                daysField
                unitText
            }
        }
    }

    @ViewBuilder
    private var daysField: some View {
        TextField("", value: daysBinding, format: .number)
            .textFieldStyle(.roundedBorder)
            .frame(width: 50)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .disabled(range == nil)
        Stepper("", value: daysBinding, in: 1...Int.max)
            .labelsHidden()
            .disabled(range == nil)
    }

    @ViewBuilder
    private var unitText: some View {
        // "日" は Localizable.xcstrings 経由で "days" に翻訳される想定。
        Text("日")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var directionPicker: some View {
        Picker("", selection: directionBinding) {
            // "以内" / "以前" も Localizable.xcstrings 経由で "within" / "older than" に翻訳される想定。
            Text("以内").tag(FilterState.DateRangeCondition.Direction.within)
            Text("以前").tag(FilterState.DateRangeCondition.Direction.olderThan)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 80)
        .disabled(range == nil)
    }
}
