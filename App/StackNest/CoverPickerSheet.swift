// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore
import LibraryStore
import ArchiveAdapter
import CoreGraphics
import ImageIO

/// アーカイブ / フォルダ内の全画像エントリを thumbnail grid で表示し、ユーザが表紙ページを選択する sheet。
/// Detail Pane の表紙エリア右クリック「表紙を選択…」から起動される (Task 8 で wire)。
/// Phase 2.5h A18-ext: 選択後の page に crop 矩形を指定して横長カバーの一部だけを表示できる。
/// crop が全体 (full rect) のままなら NULL を渡し、現行挙動を維持する。
struct CoverPickerSheet: View {
    let book: BookRow
    let bundleURL: URL
    /// 選択されたエントリ名 + crop 矩形 (nil = 全体) を受け取るコールバック (sheet は自動 dismiss)
    let onSelect: (String, CGRect?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [String] = []
    @State private var loading: Bool = true
    @State private var errorMessage: String?

    // Phase 2.5h A18-ext: ユーザが選択中のエントリ + crop 状態。
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
            Text("表紙を選択")
                .font(.title2.bold())
                .padding(.bottom, 4)

            content

            cropEditorSection

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let entry = selectedEntry else { return }
                    let cropToSave: CGRect? = (cropRect == Self.fullRect) ? nil : cropRect
                    onSelect(entry, cropToSave)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedEntry == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 500)
        .task { await loadEntries() }
        .onAppear {
            // 既存 crop 矩形を初期値に反映 (該当 book に crop が設定済みの場合)。
            if let existing = book.coverCropRect {
                cropRect = existing
                cropWidthSlider = Double(existing.width)
                cropHeightSlider = Double(existing.height)
                showCropEditor = true
            }
            // 既に選択済みの cover_image_name があれば、初期 selection とする。
            if let current = book.coverImageName {
                selectedEntry = current
            }
        }
        .onChange(of: selectedEntry) { _, newValue in
            // 選択変更時に preview image を更新。
            Task { await loadPreview(forEntry: newValue) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            Text("画像エントリが見つかりませんでした")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(entries, id: \.self) { entry in
                        CoverPickerThumbnail(
                            book: book,
                            entryName: entry,
                            isCurrent: entry == selectedEntry
                        ) {
                            selectedEntry = entry
                        }
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// Phase 2.5h A18-ext: crop 矩形編集 UI。DisclosureGroup で折り畳み可能。
    /// 既存ユーザ (crop 不使用) には UI を圧迫しないよう default は collapsed。
    @ViewBuilder
    private var cropEditorSection: some View {
        DisclosureGroup(isExpanded: $showCropEditor) {
            if let preview = previewImage {
                VStack(spacing: 8) {
                    CoverCropPicker(image: preview, normalizedRect: $cropRect)
                        .frame(height: 280)
                    HStack {
                        Text("幅")
                        Slider(value: $cropWidthSlider, in: 0.1...1.0)
                            .onChange(of: cropWidthSlider) { _, newValue in
                                var r = cropRect
                                r.size.width = newValue
                                r.origin.x = min(r.origin.x, 1 - newValue)
                                cropRect = r
                            }
                    }
                    HStack {
                        Text("高さ")
                        Slider(value: $cropHeightSlider, in: 0.1...1.0)
                            .onChange(of: cropHeightSlider) { _, newValue in
                                var r = cropRect
                                r.size.height = newValue
                                r.origin.y = min(r.origin.y, 1 - newValue)
                                cropRect = r
                            }
                    }
                    HStack {
                        Button("リセット (全体)") {
                            cropRect = Self.fullRect
                            cropWidthSlider = 1
                            cropHeightSlider = 1
                        }
                        Spacer()
                    }
                }
                .padding(.top, 8)
            } else {
                Text("ページを選択すると crop 編集できます")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
        } label: {
            Text("切り取り").font(.title2.bold())
        }
    }

    private func loadEntries() async {
        guard let path = book.path else {
            await MainActor.run {
                self.errorMessage = "ファイル パスが見つかりません"
                self.loading = false
            }
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let extractor = ArchiveAdapter.coverExtractor(for: url) else {
            await MainActor.run {
                self.errorMessage = "未対応のフォーマットです"
                self.loading = false
            }
            return
        }
        do {
            let names = try await extractor.listImageEntries(in: url)
            await MainActor.run {
                self.entries = names
                self.loading = false
            }
            // 初期 selection (book.coverImageName) があれば preview を先読み。
            if let current = selectedEntry {
                await loadPreview(forEntry: current)
            }
        } catch {
            await MainActor.run {
                self.errorMessage = "ページ一覧の取得に失敗: \(error.localizedDescription)"
                self.loading = false
            }
        }
    }

    /// crop editor 用の full-size preview を読み込む。
    /// thumbnail grid は別経路で読み込まれるが、こちらは crop 編集に十分な解像度が必要。
    private func loadPreview(forEntry entry: String?) async {
        guard let entry, let path = book.path else {
            await MainActor.run { self.previewImage = nil }
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let extractor = ArchiveAdapter.coverExtractor(for: url) else { return }
        do {
            let data = try await extractor.extractCoverImage(from: url, preferredName: entry)
            if let img = NSImage(data: data) {
                await MainActor.run { self.previewImage = img }
            }
        } catch {
            await MainActor.run { self.previewImage = nil }
        }
    }
}

/// 各ページの thumbnail (lazy 生成、選択 indicator 付き)。
private struct CoverPickerThumbnail: View {
    let book: BookRow
    let entryName: String
    let isCurrent: Bool
    let onTap: () -> Void
    @State private var image: CGImage?
    @State private var loadFailed: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if loadFailed {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 100, height: 100)
            .background(Color.gray.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isCurrent ? Color.accentColor : Color.gray.opacity(0.3),
                            lineWidth: isCurrent ? 3 : 1)
            )

            Text(entryName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 100)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .task { await loadImage() }
    }

    private func loadImage() async {
        guard let path = book.path else {
            await MainActor.run { self.loadFailed = true }
            return
        }
        let url = URL(fileURLWithPath: path)
        guard let extractor = ArchiveAdapter.coverExtractor(for: url) else {
            await MainActor.run { self.loadFailed = true }
            return
        }
        do {
            let data = try await extractor.extractCoverImage(from: url, preferredName: entryName)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceShouldCacheImmediately: true,
                      kCGImageSourceThumbnailMaxPixelSize: 200,
                      kCGImageSourceCreateThumbnailWithTransform: true,  // EXIF orientation を反映
                  ] as CFDictionary) else {
                await MainActor.run { self.loadFailed = true }
                return
            }
            await MainActor.run { self.image = cg }
        } catch {
            await MainActor.run { self.loadFailed = true }
        }
    }
}
