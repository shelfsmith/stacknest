// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore

extension LibrarySettingsSheet {
    @ViewBuilder
    func watchSection() -> some View {
        // 自動追加を 1 カードに統合: 有効トグル → 追加/スキャンボタン → 監視フォルダリスト。
        GroupBox("自動追加") {
            VStack(alignment: .leading, spacing: 12) {
                // 1) 機能 ON/OFF（チェックボックス・通常字）
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("自動追加を有効にする", isOn: $settings.folderWatchEnabled)
                        .toggleStyle(.checkbox)
                    Text("監視フォルダ直下に入った本を自動でライブラリに追加します。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                // 2) フォルダを追加 / 今すぐスキャン → 3) 監視フォルダリスト（OFF 時はグレーアウト）
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("フォルダを追加…") { addWatchFolder() }
                        Button("今すぐスキャン") { appState?.scanWatchedFoldersNow() }
                            .disabled(settings.watchedFolders.isEmpty)
                        Spacer()
                    }

                    if settings.watchedFolders.isEmpty {
                        Text("監視フォルダが未設定です。「フォルダを追加…」で指定してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach($settings.watchedFolders) { $folder in
                        watchRow($folder)
                        Divider()
                    }

                    Text("本（アーカイブ/PDF/画像/フォルダ）を移動せずその場所を参照して追加します（追加のみ・サブフォルダは対象外）。NAS など共有ボリュームでは最大 60 秒で反映されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!settings.folderWatchEnabled)
                .opacity(settings.folderWatchEnabled ? 1 : 0.4)
            }
            .padding(8)
        }
        // 行削除・有効トグル・ON/OFF・プリセット変更を即 watcher へ反映（save() を待たない）。
        .onChange(of: settings.folderWatchEnabled) { appState?.reloadFolderWatcher() }
        .onChange(of: settings.watchedFolders) { appState?.reloadFolderWatcher() }
    }

    @ViewBuilder
    private func watchRow(_ folder: Binding<WatchedFolder>) -> some View {
        let exists = FileManager.default.fileExists(atPath: folder.wrappedValue.path)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: folder.enabled).labelsHidden()
                Text(folder.wrappedValue.path)
                    .lineLimit(1).truncationMode(.middle)
                    .help(folder.wrappedValue.path)
                    .foregroundStyle(exists ? Color.primary : Color.red)   // パス不在は赤表示（4.2d-1 §6）
                if !exists {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .help("フォルダが見つかりません（アクセス不可/未マウント）。スキャンはスキップされます。")
                }
                Spacer()
                Button(role: .destructive) {
                    // id を mutation 前にローカルへ退避。removeAll(where:) の inout 排他アクセス中に
                    // 述語が folder.wrappedValue（= settings.watchedFolders への要素 Binding 読取）へ
                    // 触れると排他アクセス違反で abort する（smoke v1 E2 クラッシュの根本原因）。
                    let removingID = folder.wrappedValue.id
                    settings.watchedFolders.removeAll { $0.id == removingID }
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
            }
            HStack {
                Text("フォーマット").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { folder.wrappedValue.presetID ?? "" },
                    set: { folder.wrappedValue.presetID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("ライブラリ既定").tag("")
                    ForEach(settings.filenameFormatPresets) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
        }
    }

    func addWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for dir in panel.urls {
            if settings.watchedFolders.contains(where: { $0.path == dir.path }) { continue }
            let existing: Set<String> = Set((try? appState?.database?.fetchAllBooks().compactMap { $0.path }) ?? [])
            let top = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            let candidates = WatchFolderScanner.importable(
                topLevel: top, existingLibraryPaths: existing, baseline: [])
            let alert = NSAlert()
            alert.messageText = "「\(dir.lastPathComponent)」を監視フォルダに追加"
            if candidates.isEmpty {
                alert.informativeText = "現在、未登録の取り込み候補はありません。以降に追加されたファイルを自動取込します。"
                alert.addButton(withTitle: "追加")
                alert.addButton(withTitle: "キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn else { continue }
                settings.watchedFolders.append(WatchedFolder(id: UUID().uuidString, path: dir.path))
            } else {
                alert.informativeText = "\(candidates.count) 件の未登録ファイルが見つかりました。今すぐ取り込みますか?"
                alert.addButton(withTitle: "取り込む")
                alert.addButton(withTitle: "既存はスキップ")
                alert.addButton(withTitle: "キャンセル")
                let resp = alert.runModal()
                if resp == .alertThirdButtonReturn { continue }
                if resp == .alertSecondButtonReturn {
                    settings.watchedFolders.append(WatchedFolder(
                        id: UUID().uuidString, path: dir.path, baseline: candidates.map { $0.path }))
                } else {
                    // 「取り込む」: フォルダ登録＋確定済み候補を即時取込（デバウンス待ちしない）。
                    settings.watchedFolders.append(WatchedFolder(id: UUID().uuidString, path: dir.path))
                    appState?.importWatchedCandidatesNow(candidates, presetID: nil)
                }
            }
        }
        appState?.reloadFolderWatcher()
    }
}
