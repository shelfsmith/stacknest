// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

struct KeyBindingsSettingsView: View {
    /// キー設定は内蔵ビューア専用。外部ビューア選択時は false でグレーアウトする。
    var enabled: Bool = true

    /// G54-S1: 開閉のたびに親へ通知する。親はこれを SettingsWindowFixedSize の
    /// contentRevision（単調増加のカウンタ）に反映し、窓の高さを測り直させる（開閉は tab を
    /// 変えないため、これが無いと updateNSView が発火せず高さが追従しない）。
    /// 値そのもの（開いている節の数）ではなく通知にしているのは、このビューが再構築され
    /// `expanded` が `[]` にリセットされても、親側のカウンタとの食い違いで通知が飲み込まれない
    /// ようにするため。
    var onHeightChange: () -> Void

    @State private var bindings = ViewerKeyBindings.load()
    @State private var capturingAction: ViewerAction?
    @State private var conflictMessage: [ViewerAction: String] = [:]

    /// 既定はすべて閉じる。開閉は永続しない（毎回閉じた状態で開く）。
    @State private var expanded: Set<ViewerActionSection> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !enabled {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("キー設定は内蔵ビューア選択時のみ有効です。設定 ▸ 表示 でビューアを「内蔵ビューア」に切り替えてください。")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            Group {
                ForEach(ViewerActionSection.allCases, id: \.self) { section in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(section) },
                        set: { isOpen in
                            if isOpen { expanded.insert(section) } else { expanded.remove(section) }
                            onHeightChange()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(section.actions, id: \.self) { action in
                                row(for: action)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        HStack(spacing: 8) {
                            Text(section.title).font(.headline)
                            let changed = bindings.changedCount(in: section)
                            if changed > 0 {
                                Text("\(changed) 件変更")
                                    .font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Esc は常にキャンセル / 閉じるに使われるため固定です。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Button("すべて既定に戻す") {
                    bindings.resetAll()
                    conflictMessage.removeAll()
                    persist()
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
    }

    @ViewBuilder
    private func row(for action: ViewerAction) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(action.displayName).frame(width: 180, alignment: .leading)
                ForEach(bindings.boundBindings(for: action), id: \.self) { capture in
                    let fixed = ViewerKeyBindings.isFixed(capture)
                    chip(label: display(capture), removable: !fixed) {
                        bindings.remove(capture, from: action)
                        conflictMessage[action] = nil
                        persist()
                    }
                }
                Spacer(minLength: 4)
                if capturingAction == action {
                    Text("キーを押してください…（Esc でキャンセル）")
                        .font(.caption).foregroundStyle(.secondary)
                    KeyCaptureField(
                        isCapturing: Binding(get: { capturingAction == action }, set: { if !$0 { capturingAction = nil } }),
                        onCapture: { handleCapture($0, for: action) },
                        onCancel: { capturingAction = nil }
                    )
                    .frame(width: 1, height: 1)
                } else {
                    Button("＋ 追加") { conflictMessage[action] = nil; capturingAction = action }
                        .controlSize(.small)
                    Button("既定に戻す") { bindings.resetAction(action); conflictMessage[action] = nil; persist() }
                        .controlSize(.small)
                }
            }
            if let msg = conflictMessage[action] {
                Text(msg).font(.caption).foregroundStyle(.red).padding(.leading, 188)
            }
        }
    }

    private func chip(label: String, removable: Bool, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 11, design: .monospaced))
                .lineLimit(1).fixedSize()   // チップ内で "Space"→S/p/a/c/e と文字折り返ししない
            if removable {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            } else {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color(nsColor: .quaternarySystemFill), in: Capsule())
        .help(removable ? "" : "Esc は「閉じる」に固定（キー キャプチャのキャンセルに使用するため再割当できません）")
    }

    private func display(_ capture: CapturedBinding) -> String {
        switch capture {
        case .chord(let c): return KeyDisplay.chord(c)
        case .character(let s): return KeyDisplay.character(s)
        }
    }

    private func handleCapture(_ capture: CapturedBinding, for action: ViewerAction) {
        capturingAction = nil
        switch bindings.assign(capture, to: action) {
        case .success:
            conflictMessage[action] = nil
            persist()
        case .failure(let conflict):
            conflictMessage[action] = "このキーは「\(conflict.existing.displayName)」に使用中です"
        }
    }

    private func persist() { bindings.save() }
}
