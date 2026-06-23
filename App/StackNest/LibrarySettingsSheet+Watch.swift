// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore

extension LibrarySettingsSheet {
    @ViewBuilder
    func watchSection() -> some View {
        GroupBox("監視フォルダ") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("自動追加を有効にする", isOn: $settings.folderWatchEnabled)
                    .toggleStyle(.switch)   // 機能全体の ON/OFF。下のフォルダ毎チェックボックスと区別
                    .font(.headline)

                Group {
                    if settings.watchedFolders.isEmpty {
                        Text("監視フォルダが未設定です。「フォルダを追加…」で指定してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach($settings.watchedFolders) { $folder in
                        watchRow($folder)
                        Divider()
                    }
                    HStack {
                        Button("フォルダを追加…") { addWatchFolder() }
                        Button("今すぐスキャン") { appState?.scanWatchedFoldersNow() }
                            .disabled(settings.watchedFolders.isEmpty)
                        Spacer()
                    }
                }
                .disabled(!settings.folderWatchEnabled)
                .opacity(settings.folderWatchEnabled ? 1 : 0.4)

                Text("監視フォルダ直下に入った本（アーカイブ/PDF/画像/フォルダ）を自動でライブラリに追加します（移動せずその場所を参照・追加のみ・サブフォルダは対象外）。NAS など共有ボリュームでは最大 60 秒で反映されます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
        }
        // 行削除・有効トグル・ON/OFF・プリセット変更を即 watcher へ反映（save() を待たない）。
        .onChange(of: settings.folderWatchEnabled) { appState?.reloadFolderWatcher() }
        .onChange(of: settings.watchedFolders) { appState?.reloadFolderWatcher() }
    }

    @ViewBuilder
    private func watchRow(_ folder: Binding<WatchedFolder>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("", isOn: folder.enabled).labelsHidden()
                Text(folder.wrappedValue.path)
                    .lineLimit(1).truncationMode(.middle)
                    .help(folder.wrappedValue.path)
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
