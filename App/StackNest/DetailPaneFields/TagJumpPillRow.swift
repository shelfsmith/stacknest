// SPDX-License-Identifier: MIT
import SwiftUI

/// Renders a comma-separated tag string as a row of pills, each with a
/// "→" jump button (A29). Used under EditableTextField for tag-style fields.
/// Empty/nil string renders nothing.
struct TagJumpPillRow: View {
    let value: String?
    let onJump: (String) -> Void

    var body: some View {
        if let tags = parsed, !tags.isEmpty {
            FlowLayout(spacing: 4) {
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    HStack(spacing: 2) {
                        Text(tag)
                            .padding(.leading, 8)
                            .padding(.vertical, 2)
                        Button {
                            onJump(tag)
                        } label: {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                        .help(Text("「\(tag)」で絞り込む"))
                        .accessibilityLabel(Text("「\(tag)」で絞り込む"))
                    }
                    .background(.tertiary, in: Capsule())
                }
            }
        }
    }

    private var parsed: [String]? {
        guard let v = value else { return nil }
        let trimmed = v.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return trimmed
    }
}
