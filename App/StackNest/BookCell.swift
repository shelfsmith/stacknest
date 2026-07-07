// SPDX-License-Identifier: MIT
import SwiftUI
import CoreGraphics
import LibraryStore
import ImageCache
import OSLog

struct BookCell: View {
    let book: BookRow
    let loader: ThumbnailLoader?
    /// G4c: 表紙差し替え（メタ不変）でも再描画/再取得させる版数。ローカルグリッド用。
    var coverVersion: Int = 0

    @State private var thumbnail: CGImage?

    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "CoverReflow")

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let cgImage = thumbnail {
                    Image(decorative: Self.croppedImage(cgImage, rect: book.coverCropRect), scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.15))
                        .aspectRatio(2.0/3.0, contentMode: .fit)
                        .overlay(
                            Image(systemName: "book.closed")
                                .resizable()
                                .scaledToFit()
                                .padding(20)
                                .foregroundStyle(.secondary)
                        )
                }
            }
            // coverImageName 変化時に view identity を更新して SwiftUI に強制再描画させる。
            // .task(id:) だけでは @State thumbnail 更新後も view が skip される場合がある。
            .id("\(book.id):\(book.coverImageName ?? ""):\(book.coverCropRect.map { "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)" } ?? ""):\(coverVersion)")
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(radius: 2, y: 1)

            Text(book.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let author = book.author {
                Text(author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: "\(book.id):\(book.coverImageName ?? ""):\(book.coverCropRect.map { "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)" } ?? ""):\(coverVersion)") {
            let taskID = "\(book.id):\(book.coverImageName ?? ""):\(book.coverCropRect.map { "\($0.origin.x),\($0.origin.y),\($0.size.width),\($0.size.height)" } ?? ""):\(coverVersion)"
            Self.logger.info("BookCell.task: id=\(taskID)")
            guard let loader else { return }
            let loaded = await loader.thumbnail(for: book.id, maxPixelSize: 400)
            Self.logger.info("BookCell.task: thumbnail loaded, found=\(loaded != nil), id=\(taskID)")
            self.thumbnail = loaded
        }
    }

    /// Phase 2.5h A18-ext: 横長カバー対応。
    /// `rect` が nil または全体 (full image rect) なら元画像を返し、その他は CGImage を切り出す。
    /// CGImage.cropping(to:) は thumbnail cache を汚さないため、purge 不要。
    /// 4.2c-6b: リモートグリッド（RemoteBookCell）でも同一ロジックを使うため internal。
    static func croppedImage(_ image: CGImage, rect: CGRect?) -> CGImage {
        guard let rect, rect != CGRect(x: 0, y: 0, width: 1, height: 1) else {
            return image
        }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let pixelRect = CGRect(
            x: rect.origin.x * w,
            y: rect.origin.y * h,
            width: rect.size.width * w,
            height: rect.size.height * h
        ).integral
        return image.cropping(to: pixelRect) ?? image
    }
}
