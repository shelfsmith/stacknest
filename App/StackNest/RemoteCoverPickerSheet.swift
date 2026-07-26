// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import LibraryStore
import CoreGraphics

/// 4.2c-6b: リモート用の表紙ピッカー。エントリ一覧/プレビューはサーバ API（注入クロージャ）から取得。
/// ローカル CoverPickerSheet を mirror（クロップ編集は共用 CoverCropPicker を再利用）。
struct RemoteCoverPickerSheet: View {
    let book: BookRow
    let loadCandidates: () async -> (entries: [String], current: String?)
    let loadEntryImage: (String) async -> NSImage?
    let onSelect: (String, CGRect?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [String] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var selectedEntry: String?
    @State private var previewImage: NSImage?
    @State private var showCropEditor = false
    @State private var cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var cropWidthSlider: Double = 1.0
    @State private var cropHeightSlider: Double = 1.0

    private static let fullRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 110), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("表紙を選択").font(.title2.bold()).padding(.bottom, 4)
            content
            cropEditorSection
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let entry = selectedEntry else { return }
                    onSelect(entry, cropRect == Self.fullRect ? nil : cropRect)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(selectedEntry == nil)
            }
        }
        .padding(20).frame(minWidth: 600, minHeight: 500)
        .task { await load() }
        .onAppear {
            if let existing = book.coverCropRect {
                cropRect = existing
                cropWidthSlider = Double(existing.width)
                cropHeightSlider = Double(existing.height)
                showCropEditor = true
            }
            if let current = book.coverImageName { selectedEntry = current }
        }
        .onChange(of: selectedEntry) { _, v in Task { await loadPreview(v) } }
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text(errorMessage).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            Text("画像エントリが見つかりませんでした").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries, id: \.self) { entry in
                        RemoteCoverThumbnail(entryName: entry, isCurrent: entry == selectedEntry,
                                             load: { await loadEntryImage(entry) }) { selectedEntry = entry }
                    }
                }.padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder private var cropEditorSection: some View {
        DisclosureGroup(isExpanded: $showCropEditor) {
            if let preview = previewImage {
                VStack(spacing: 8) {
                    CoverCropPicker(image: preview, normalizedRect: $cropRect).frame(height: 280)
                    HStack {
                        Text("幅")
                        Slider(value: $cropWidthSlider, in: 0.1...1.0).onChange(of: cropWidthSlider) { _, nv in
                            var r = cropRect; r.size.width = nv; r.origin.x = min(r.origin.x, 1 - nv); cropRect = r
                        }
                    }
                    HStack {
                        Text("高さ")
                        Slider(value: $cropHeightSlider, in: 0.1...1.0).onChange(of: cropHeightSlider) { _, nv in
                            var r = cropRect; r.size.height = nv; r.origin.y = min(r.origin.y, 1 - nv); cropRect = r
                        }
                    }
                    HStack { Button("リセット (全体)") { cropRect = Self.fullRect; cropWidthSlider = 1; cropHeightSlider = 1 }; Spacer() }
                }.padding(.top, 8)
            } else {
                Text("ページを選択すると crop 編集できます").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 12)
            }
        } label: { Text("切り取り").font(.title2.bold()) }
    }

    private func load() async {
        let (names, _) = await loadCandidates()
        await MainActor.run {
            self.entries = names
            self.loading = false
            if names.isEmpty { self.errorMessage = "画像エントリが見つかりませんでした" }
        }
        if let current = selectedEntry { await loadPreview(current) }
    }

    private func loadPreview(_ entry: String?) async {
        guard let entry else { await MainActor.run { previewImage = nil }; return }
        let img = await loadEntryImage(entry)
        await MainActor.run { previewImage = img }
    }
}

/// 各ページの thumbnail（注入クロージャで画像取得）。
private struct RemoteCoverThumbnail: View {
    let entryName: String
    let isCurrent: Bool
    let load: () async -> NSImage?
    let onTap: () -> Void
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                else if failed { Image(systemName: "photo.badge.exclamationmark").font(.title).foregroundStyle(.secondary) }
                else { ProgressView() }
            }
            .frame(width: 100, height: 100).background(Color.gray.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(isCurrent ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: isCurrent ? 3 : 1))
            Text(entryName).font(.caption).lineLimit(1).truncationMode(.middle).frame(width: 100)
        }
        .contentShape(Rectangle()).onTapGesture { onTap() }
        .task { let img = await load(); await MainActor.run { if let img { image = img } else { failed = true } } }
    }
}
