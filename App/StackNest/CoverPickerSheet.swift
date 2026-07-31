// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import LibraryStore
import ArchiveAdapter
import CoreGraphics
import ImageIO

/// crop editor 用 preview の読み込み結果。
/// `.unchanged` はローカル経路の従来挙動（画像データは取れたが `NSImage` 化に失敗したときは
/// 直前の preview を残す）を共有シェルでそのまま再現するために必要。
/// リモート経路は `.image` / `.cleared` しか返さない（従来どおり nil で消える）。
enum CoverPreviewLoadResult {
    case image(NSImage)
    case cleared
    case unchanged
}

/// 表紙ピッカーのデータ取得経路。ローカルは ArchiveAdapter 直読み、リモートは注入クロージャ。
/// 共有シェル (`CoverPickerSheet`) はこの struct 経由でしかデータに触らないので、
/// リモート実行時にローカル専用 API（ArchiveAdapter / ファイル直読み）へ到達することはない。
struct CoverPickerSource {
    /// 画像エントリ一覧。`errorMessage` が非 nil ならグリッドの代わりに⚠️エラー表示になる。
    let listEntries: () async -> (entries: [String], errorMessage: String?)
    /// grid 用 thumbnail を 1 枚。nil を返すと失敗アイコンになる。
    /// 描画パスを経路ごとに変えられるよう `Image` を返す（ローカル=ImageIO で 200px 縮小した
    /// CGImage、リモート=サーバから受けた NSImage）。
    let thumbnail: (String) async -> Image?
    /// crop 編集に足る解像度の full-size preview。
    let preview: (String) async -> CoverPreviewLoadResult
}

/// アーカイブ / フォルダ内の全画像エントリを thumbnail grid で表示し、ユーザが表紙ページを選択する sheet。
/// Detail Pane の表紙エリア右クリック「表紙を選択…」から起動される (Task 8 で wire)。
/// Phase 2.5h A18-ext: 選択後の page に crop 矩形を指定して横長カバーの一部だけを表示できる。
/// crop が全体 (full rect) のままなら NULL を渡し、現行挙動を維持する。
/// G25b-2 P4: ローカル / リモート (`RemoteCoverPickerSheet`) で UI シェルを共有し、
/// 経路差は `CoverPickerSource` のクロージャだけに閉じ込める。
struct CoverPickerSheet: View {
    let book: BookRow
    let source: CoverPickerSource
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
                            entryName: entry,
                            isCurrent: entry == selectedEntry,
                            load: { await source.thumbnail(entry) }
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
        let (names, error) = await source.listEntries()
        await MainActor.run {
            self.entries = names
            self.errorMessage = error
            self.loading = false
        }
        // 初期 selection (book.coverImageName) があれば preview を先読み。
        if let current = selectedEntry {
            await loadPreview(forEntry: current)
        }
    }

    /// crop editor 用の full-size preview を読み込む。
    /// thumbnail grid は別経路で読み込まれるが、こちらは crop 編集に十分な解像度が必要。
    private func loadPreview(forEntry entry: String?) async {
        guard let entry else {
            await MainActor.run { self.previewImage = nil }
            return
        }
        switch await source.preview(entry) {
        case .image(let img):
            await MainActor.run { self.previewImage = img }
        case .cleared:
            await MainActor.run { self.previewImage = nil }
        case .unchanged:
            break
        }
    }
}

extension CoverPickerSheet {
    /// ローカル用の初期化（ArchiveAdapter でアーカイブ / フォルダを直読み）。
    init(book: BookRow, onSelect: @escaping (String, CGRect?) -> Void) {
        self.init(book: book, source: .local(book: book), onSelect: onSelect)
    }
}

extension CoverPickerSource {
    /// ローカル経路。`book.path` は sheet 生存中は不変なので値だけ捕捉する
    /// (BookRow ごと捕捉しない)。実処理は nonisolated な static func 側にあるので、
    /// ImageIO のデコードが MainActor に載ることはない。
    /// `fileprivate`: リモート経路からローカル専用のアーカイブ読み出しに到達できないことを、
    /// 規約ではなく**型で**担保する（このファイルの外からは呼べない）。
    fileprivate static func local(book: BookRow) -> CoverPickerSource {
        let path = book.path
        return CoverPickerSource(
            listEntries: { await LocalCoverEntryLoader.entries(path: path) },
            thumbnail: { await LocalCoverEntryLoader.thumbnail(path: path, entry: $0) },
            preview: { await LocalCoverEntryLoader.preview(path: path, entry: $0) }
        )
    }
}

/// ローカル経路の実処理（ArchiveAdapter）。
private enum LocalCoverEntryLoader {
    static func entries(path: String?) async -> (entries: [String], errorMessage: String?) {
        guard let path else { return ([], "ファイル パスが見つかりません") }
        let url = URL(fileURLWithPath: path)
        guard let extractor = ArchiveAdapter.coverExtractor(for: url) else {
            return ([], "未対応のフォーマットです")
        }
        do {
            return (try await extractor.listImageEntries(in: url), nil)
        } catch {
            return ([], "ページ一覧の取得に失敗: \(error.localizedDescription)")
        }
    }

    static func thumbnail(path: String?, entry: String) async -> Image? {
        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let extractor = ArchiveAdapter.coverExtractor(for: url),
              let data = try? await extractor.extractCoverImage(from: url, preferredName: entry),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: 200,
                  kCGImageSourceCreateThumbnailWithTransform: true,  // EXIF orientation を反映
              ] as CFDictionary) else {
            return nil
        }
        return Image(decorative: cg, scale: 1.0)
    }

    static func preview(path: String?, entry: String) async -> CoverPreviewLoadResult {
        guard let path else { return .cleared }
        let url = URL(fileURLWithPath: path)
        guard let extractor = ArchiveAdapter.coverExtractor(for: url) else { return .unchanged }
        do {
            let data = try await extractor.extractCoverImage(from: url, preferredName: entry)
            // デコードに失敗したときは直前の preview を残す（従来挙動）。
            guard let img = NSImage(data: data) else { return .unchanged }
            return .image(img)
        } catch {
            return .cleared
        }
    }
}

/// 各ページの thumbnail (lazy 生成、選択 indicator 付き)。ローカル / リモート共用
/// （画像取得だけ `CoverPickerSource.thumbnail` に委譲する）。
private struct CoverPickerThumbnail: View {
    let entryName: String
    let isCurrent: Bool
    let load: () async -> Image?
    let onTap: () -> Void
    @State private var image: Image?
    @State private var loadFailed: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let image {
                    image
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
        .task {
            let loaded = await load()
            await MainActor.run {
                if let loaded { self.image = loaded } else { self.loadFailed = true }
            }
        }
    }
}
