// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore

struct KeyBindingsSettingsView: View {
    @State private var bindings = ViewerKeyBindings.load()
    @State private var capturingAction: ViewerAction?
    @State private var conflictMessage: [ViewerAction: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ViewerActionSection.allCases, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.headline)
                        ForEach(section.actions, id: \.self) { action in
                            row(for: action)
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
            .padding(16)
        }
        .frame(maxHeight: .infinity)   // ウィンドウ高（tab3 固定値）いっぱいに伸ばす
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
