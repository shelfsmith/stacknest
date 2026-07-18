// SPDX-License-Identifier: MIT
//
// G18 C1: off-main の即時（eager）縮小デコーダ。
//
// ビューア（本文閲覧）は従来、フル解像度画像を CGImage 化 → 画面表示のたびに ImageIO が
// 遅延デコード（draw 時に初めてデコードが走る "lazy decode"）していたため、ページめくりの
// たびにメインスレッドで大きな JPEG/PNG デコードが走り、UI がフリーズしていた
// （Intel 実機で顕著）。
//
// 対策は ThumbnailLoader (Sources/ImageCache/ThumbnailLoader.swift) が既に使っている
// パターンをそのままミラーする: CGImageSourceCreateThumbnailAtIndex に
// kCGImageSourceShouldCacheImmediately: true を渡すと、呼び出し時点でピクセルデータが
// 即座に展開される（lazy decode を回避）。これをバックグラウンドスレッドで呼べば、
// メインスレッドは「もうデコード済みの CGImage」を受け取って draw するだけになる。
//
// この型は nonisolated（MainActor 隔離なし）。呼び出し側（ビューアのロード処理）が
// Task.detached や background actor から呼ぶことを想定しており、この関数自体が
// メインスレッドへホップすることは一切ない。

import Foundation
import CoreGraphics
import ImageIO

/// 即時デコード済みの CGImage と、その実ピクセルサイズ。
///
/// `CGImage` は不変（immutable）オブジェクトであり、生成後に内容が変化することはない。
/// Swift の `Sendable` 自動合成は `CGImage`（Objective-C ブリッジ型）に届かないため、
/// 「不変だから複数スレッド間で安全に共有できる」という前提を明示する目的で
/// `@unchecked Sendable` を付与する（実体としては安全性チェックを人手で保証している）。
public struct DecodedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelSize: CGSize

    public init(cgImage: CGImage, pixelSize: CGSize) {
        self.cgImage = cgImage
        self.pixelSize = pixelSize
    }
}

/// off-main で呼び出し可能な、即時展開（eager decode）＋表示サイズ縮小のデコーダ。
///
/// `nonisolated` であり、いかなる Actor にも隔離されない。呼び出し側がどのスレッド/Task
/// から呼んでも、この関数自体がメインスレッドに戻ることはない（MainActor 隔離コードを
/// 一切含まない）。
public enum ViewerImageDecoder {
    /// `data` を即時デコードし、必要なら `maxPixelSize` 以下に縮小した `CGImage` を返す。
    ///
    /// - Parameters:
    ///   - data: 画像バイト列（JPEG/PNG 等、ImageIO が認識できる形式）。
    ///   - maxPixelSize: 返す CGImage の最大辺（縦横のうち長い方）の上限。
    ///     `0` 以下を渡すとフル解像度（ネイティブ解像度）で即時デコードする
    ///     （ズーム時の再デコード用途）。
    /// - Returns: 即時デコード済みの `DecodedImage`。デコード不能なデータなら `nil`。
    public static func decode(_ data: Data, maxPixelSize: Int) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let cgImage: CGImage?
        if maxPixelSize > 0 {
            // ThumbnailLoader.thumbnail(for:maxPixelSize:) と同一パターン（意図的にミラー）。
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,  // EXIF orientation を反映
            ] as CFDictionary)
        } else {
            // フル解像度（縮小なし）。kCGImageSourceShouldCacheImmediately で即時展開しつつ、
            // kCGImageSourceCreateThumbnailWithTransform 相当の EXIF 回転も適用したいため、
            // CGImageSourceCreateImageAtIndex ではなく、上限を極端に大きくした thumbnail 生成
            // を使う（同一コードパスを通すことで EXIF 回転の扱いを一貫させる）。
            cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.nativeResolutionSentinel,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        }

        guard let image = cgImage else { return nil }
        return DecodedImage(cgImage: image, pixelSize: CGSize(width: image.width, height: image.height))
    }

    /// フル解像度デコード時に thumbnail API へ渡す「縮小させない」ための上限値。
    /// 実在する画像の最大辺がこれを超えることは実運用上ない（想定: 数万 px 級のスキャン画像でも収まる）。
    private static let nativeResolutionSentinel = 1 << 16  // 65536
}
