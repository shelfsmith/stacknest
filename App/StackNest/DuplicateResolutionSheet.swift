// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore
import LibraryStore

struct DuplicateResolutionSheet: View {
    @Bindable var settings: LibrarySettings
    let database: Database
    let bundleURL: URL
    var appState: AppState?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .idle
    @State private var task: DuplicateScanTask?
    @State private var progress: (Int, Int) = (0, 0)
    @State private var result = DuplicateScanResult()
    /// 各グループで「残す」本の id（既定: 先頭）。key = group.key。
    @State private var keepByGroup: [String: Int] = [:]
    /// 「ファイルもゴミ箱へ」にチェックした book id。
    @State private var trashFileIDs: Set<Int> = []
    @State private var showExecuteConfirm = false

    enum Phase { case idle, scanning, results }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重複を検出").font(.title2.bold())
            switch phase {
            case .idle:
                Text("ライブラリ内の重複を検出します。完全一致（同一ファイル）と、シリーズ+巻数が一致する「同一の可能性」を表示します。")
                    .foregroundStyle(.secondary)
                if !settings.ignoredDuplicateKeys.isEmpty {
                    HStack {
                        Text("無視中の重複 \(settings.ignoredDuplicateKeys.count) 件は検出結果に表示されません。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("無視をすべて解除") { settings.ignoredDuplicateKeys = [] }
                            .controlSize(.small)
                    }
                }
                HStack { Spacer()
                    Button("キャンセル") { dismiss() }
                    Button("検出開始") { startScan() }.keyboardShortcut(.defaultAction)
                }
            case .scanning:
                ProgressView(value: Double(progress.0), total: Double(max(progress.1, 1)))
                Text("ハッシュ計算中… \(progress.0)/\(progress.1)").monospacedDigit()
                HStack { Spacer(); Button("中断") { task?.cancel() } }
            case .results:
                resultsView
            }
        }
        .padding(20).frame(minWidth: 640, minHeight: 480)
        .confirmationDialog("削除を実行します", isPresented: $showExecuteConfirm, titleVisibility: .visible) {
            Button("実行（登録 \(plannedDeleteIDs.count) 件・ファイル \(trashFileIDs.intersection(Set(plannedDeleteIDs)).count) 件）", role: .destructive) { execute() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("選択した本をライブラリから削除します。「ファイルもゴミ箱へ」にチェックした分は外部ファイルもゴミ箱へ移動します（Finder から復元可）。")
        }
    }

    @ViewBuilder private var resultsView: some View {
        if result.exact.isEmpty && result.possible.isEmpty {
            Text("重複は見つかりませんでした。" + (result.missingCount > 0 ? "（ファイル不明 \(result.missingCount) 件はスキップ）" : ""))
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !result.exact.isEmpty {
                    Text("完全一致（同一ファイル）").font(.headline)
                    ForEach(result.exact) { group in groupView(group, confident: true) }
                }
                if !result.possible.isEmpty {
                    Text("同一の可能性（シリーズ+巻数一致）").font(.headline)
                    ForEach(result.possible) { group in groupView(group, confident: false) }
                }
            }
        }
        HStack {
            Text("ファイル不明 \(result.missingCount) 件はスキップ").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("閉じる") { dismiss() }
            Button("削除を実行") { showExecuteConfirm = true }
                .disabled(plannedDeleteIDs.isEmpty)
        }
    }

    @ViewBuilder private func groupView(_ group: DuplicateGroup, confident: Bool) -> some View {
        let keepID = keepByGroup[group.key] ?? group.members.first?.id
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: confident ? "checkmark.seal.fill" : "questionmark.circle")
                        .foregroundStyle(confident ? Color.green : Color.orange)
                    Text(confident ? "完全一致（同一ファイル）" : "同一の可能性（要確認）")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                ForEach(group.members) { b in
                    HStack {
                        Image(systemName: b.id == keepID ? "largecircle.fill.circle" : "circle")
                            .onTapGesture { keepByGroup[group.key] = b.id }
                        VStack(alignment: .leading) {
                            Text(b.title).lineLimit(1)
                            Text(b.path ?? "—").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if b.id != keepID {
                            Toggle("ファイルもゴミ箱へ", isOn: Binding(
                                get: { trashFileIDs.contains(b.id) },
                                set: { on in if on { trashFileIDs.insert(b.id) } else { trashFileIDs.remove(b.id) } }
                            )).toggleStyle(.checkbox)
                        }
                    }
                }
                HStack { Spacer(); Button("このグループを無視") { settings.ignoredDuplicateKeys.insert(group.key); removeGroupFromView(group) } }
            }.padding(6)
        }
    }

    /// 残す以外の全 member id（削除予定）。無視済みグループは結果から除いてある。
    private var plannedDeleteIDs: [Int] {
        var ids: [Int] = []
        for g in result.exact + result.possible {
            let keep = keepByGroup[g.key] ?? g.members.first?.id
            ids.append(contentsOf: g.members.map(\.id).filter { $0 != keep })
        }
        return ids
    }

    private func startScan() {
        let t = DuplicateScanTask(database: database, ignoredKeys: settings.ignoredDuplicateKeys)
        task = t; phase = .scanning
        Task { @MainActor in
            let r = await t.run { p, total in progress = (p, total) }
            result = r; phase = .results
        }
    }

    private func removeGroupFromView(_ group: DuplicateGroup) {
        result.exact.removeAll { $0.key == group.key }
        result.possible.removeAll { $0.key == group.key }
    }

    private func execute() {
        let deleteIDs = plannedDeleteIDs
        // 1) ファイルをゴミ箱へ（チェックされた分のみ）
        let fm = FileManager.default
        let freshByID = Dictionary(uniqueKeysWithValues: ((try? database.fetchAllBooks()) ?? []).map { ($0.id, $0) })
        for id in deleteIDs where trashFileIDs.contains(id) {
            if let p = freshByID[id]?.path {
                try? fm.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
            }
        }
        // 2) 登録削除（既存の削除経路: DB 行 + Thumbnails、undo 対応）。
        //    シートの confirmationDialog で件数提示つき確認済みのため confirm:false（二重確認回避）。
        BookDeleteCommand.deleteFromLibrary(bookIDs: deleteIDs, database: database,
                                            bundleURL: bundleURL, appState: appState, undoManager: undoManager,
                                            confirm: false)
        dismiss()
    }
}
