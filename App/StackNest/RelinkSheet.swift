// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore
import LibraryStore

struct RelinkSheet: View {
    let database: Database
    var onApplied: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var groups: [BrokenGroup] = []
    @State private var scanned = 0
    @State private var total = 0
    @State private var scanTask: Task<Void, Never>?

    enum Phase { case idle, scanning, done }
    struct BrokenGroup: Identifiable { let id = UUID(); let directory: String; var books: [(id: Int, path: String)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("リンク切れの検出と再リンク").font(.headline)
            switch phase {
            case .idle:
                Text("本体ファイルが見つからない本を検出します。ライブラリが大きい・ネットワーク上にある場合は時間がかかることがあります。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("検出を開始") { startScan() }
            case .scanning:
                ProgressView(value: Double(scanned), total: Double(max(total, 1)))
                Text("確認中… \(scanned) / \(total)").monospacedDigit().font(.caption)
                Button("キャンセル") { scanTask?.cancel() }
            case .done:
                if groups.isEmpty {
                    Text("リンク切れはありません。").foregroundStyle(.secondary)
                } else {
                    Text("リンク切れ \(groups.reduce(0){$0+$1.books.count}) 件 / \(groups.count) フォルダ").font(.callout)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(groups) { g in
                                HStack {
                                    Text(g.directory).font(.system(size: 12, design: .monospaced))
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text("\(g.books.count) 件").font(.caption).foregroundStyle(.secondary)
                                    Button("フォルダを再指定…") { remapFolder(g) }
                                }
                                Divider()
                            }
                        }
                    }.frame(maxHeight: 360)
                }
                Button("再検出") { startScan() }
            }
            HStack { Spacer(); Button("閉じる") { scanTask?.cancel(); dismiss() } }
        }
        .padding(20).frame(width: 560, height: 480)
        .onDisappear { scanTask?.cancel() }
    }

    private func startScan() {
        phase = .scanning; scanned = 0; groups = []
        scanTask = Task {
            let books = (try? database.fetchAllBooks()) ?? []
            await MainActor.run { total = books.count }
            var broken: [(id: Int, path: String)] = []
            for b in books {
                if Task.isCancelled { break }
                if let p = b.path, !FileManager.default.fileExists(atPath: p) {
                    broken.append((id: b.id, path: p))
                }
                await MainActor.run { scanned += 1 }
            }
            if Task.isCancelled { return }
            let grouped = LinkRemap.groupByParentDirectory(broken.map(\.path))
            let result = grouped.map { gr in
                BrokenGroup(directory: gr.directory,
                            books: gr.paths.compactMap { path in broken.first { $0.path == path } })
            }
            await MainActor.run { groups = result; phase = .done }
        }
    }

    private func remapFolder(_ g: BrokenGroup) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = String(localized: "「\(g.directory)」 の新しい場所（フォルダ）を選択してください。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let newDir = url.path(percentEncoded: false)
        let pairsAll = LinkRemap.remap(paths: g.books.map(\.path), oldDir: g.directory, newDir: newDir)
        let resolvable = pairsAll.filter { FileManager.default.fileExists(atPath: $0.new) }
        let idByOld = Dictionary(uniqueKeysWithValues: g.books.map { ($0.path, $0.id) })
        let apply: [(id: Int, newPath: String)] = resolvable.compactMap { pr in
            idByOld[pr.old].map { (id: $0, newPath: pr.new) }
        }
        do {
            try database.applyRelinks(apply)
            let skipped = pairsAll.count - apply.count
            onApplied()
            startScan()
            if skipped > 0 {
                let a = NSAlert()
                a.messageText = String(localized: "\(apply.count) 件を再リンク、\(skipped) 件は新しい場所に見つからずスキップしました。")
                a.runModal()
            }
        } catch {
            let a = NSAlert(); a.messageText = String(localized: "再リンクに失敗しました")
            a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}
