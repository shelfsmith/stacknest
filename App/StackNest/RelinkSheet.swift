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
    struct BrokenBook: Identifiable { let id: Int; let title: String; let path: String }
    struct BrokenGroup: Identifiable { let id = UUID(); let directory: String; var books: [BrokenBook] }

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
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(groups) { g in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(g.directory).font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text("\(g.books.count) 件").font(.caption).foregroundStyle(.secondary)
                                        if g.books.count > 1 {
                                            Button("フォルダごと再指定…") { remapFolder(g) }.controlSize(.small)
                                        }
                                    }
                                    ForEach(g.books) { b in
                                        HStack {
                                            Text(b.title).lineLimit(1)
                                            Text((b.path as NSString).lastPathComponent)
                                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                            Button("再指定…") { relinkOne(b) }.controlSize(.small)
                                        }
                                        .padding(.leading, 12)
                                    }
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
        .padding(20)
        // idle / scanning / 結果0件 は内容サイズ（コンパクト）。結果一覧があるときだけ縦に広げる。
        .frame(
            minWidth: 560,
            idealWidth: 600,
            minHeight: hasResults ? 420 : nil,
            idealHeight: hasResults ? 520 : nil,
            alignment: .topLeading
        )
        .onDisappear { scanTask?.cancel() }
    }

    private var hasResults: Bool { phase == .done && !groups.isEmpty }

    private func startScan() {
        phase = .scanning; scanned = 0; groups = []
        scanTask = Task {
            let books = (try? database.fetchAllBooks()) ?? []
            await MainActor.run { total = books.count }
            var broken: [BrokenBook] = []
            for b in books {
                if Task.isCancelled { break }
                if let p = b.path, !FileManager.default.fileExists(atPath: p) {
                    broken.append(BrokenBook(id: b.id, title: b.title, path: p))
                }
                await MainActor.run { scanned += 1 }
            }
            if Task.isCancelled { return }
            let grouped = LinkRemap.groupByParentDirectory(broken.map(\.path))
            let result: [BrokenGroup] = grouped.map { gr in
                BrokenGroup(directory: gr.directory,
                            books: gr.paths.compactMap { path in broken.first { $0.path == path } })
            }
            await MainActor.run { groups = result; phase = .done }
        }
    }

    private func relinkOne(_ b: BrokenBook) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = String(localized: "「\(b.title)」 にリンクするファイルを選択してください。")
        panel.directoryURL = URL(fileURLWithPath: b.path).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try database.relinkBook(id: b.id, newPath: url.path(percentEncoded: false))
            onApplied()
            startScan()
        } catch {
            let a = NSAlert(); a.messageText = String(localized: "再リンクに失敗しました")
            a.informativeText = error.localizedDescription; a.runModal()
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
            onApplied(); startScan()
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
