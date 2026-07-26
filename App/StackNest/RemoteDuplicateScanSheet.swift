// SPDX-License-Identifier: MIT
import LibraryServerAPI
import SwiftUI

/// G12b-2 Task 5: `DuplicateScanReply` は Identifiable でないため、`.sheet(item:)` に渡すための
/// 薄いラッパ。スキャン結果 1 回分を一意に識別するだけで十分（内容の同一性比較は不要）。
struct RemoteDuplicateScanResult: Identifiable {
    let id = UUID()
    let reply: DuplicateScanReply
}

/// G12b-2 Task 5: リモートライブラリの重複検出結果シート（軽量版）。ローカルの
/// `DuplicateResolutionSheet` と異なり、リモートは merge/interactive resolution を持たず、
/// exact/possible グループを一覧表示 → admin は各本を「ライブラリから削除」/「ゴミ箱に移動」できる
/// だけの単純な結果ビューア（YAGNI: サムネ表示・グループ内マージ UI は今回のスコープ外）。
struct RemoteDuplicateScanSheet: View {
    let reply: DuplicateScanReply
    let state: RemoteLibraryState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重複の検出結果").font(.title2.bold())
            Text("候補 \(reply.candidateCount) / ハッシュ済 \(reply.hashedCount) / 未算出 \(reply.missingCount)")
                .font(.caption).foregroundStyle(.secondary)
            if reply.exact.isEmpty && reply.possible.isEmpty {
                Text("重複は見つかりませんでした。").padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        groupList(title: "完全一致", groups: reply.exact)
                        groupList(title: "シリーズ/巻 の可能性", groups: reply.possible)
                    }
                }
            }
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 480)
    }

    @ViewBuilder
    private func groupList(title: String, groups: [DuplicateGroupDTO]) -> some View {
        if !groups.isEmpty {
            Text(title).font(.headline).padding(.top, 6)
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(group.members, id: \.id) { book in
                            HStack {
                                Text(book.title).lineLimit(1)
                                Spacer()
                                if state.canDelete {
                                    Button("ライブラリから削除") {
                                        RemoteDeleteCommand.confirmAndDelete(ids: [book.id], state: state, trash: false)
                                    }
                                    Button("ファイルをゴミ箱に移動…") {
                                        RemoteDeleteCommand.confirmAndDelete(ids: [book.id], state: state, trash: true)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
