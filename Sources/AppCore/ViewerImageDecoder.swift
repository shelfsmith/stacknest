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

        // G19 Intel スムーズ化: 「**縮小が不要**（native ≤ target）かつ**向き up**」のときは
        // `CGImageSourceCreateThumbnailAtIndex`（thumbnail 生成）をやめて `CGImageSourceCreateImageAtIndex`
        // を使う。本機では後者は `ShouldCacheImmediately` を付けても即時展開せず**フル解像度の遅延
        // CGImage**を返し（ピクセル展開は draw 時）、実測でも thumbnail 経路より高速。これにより
        // ページ送りは cooViewer と同一機構になる: **先読みは軽い遅延画像を作るだけ（競合なし）→
        // 実デコードは描画時にメインで 1 枚ずつ**。上位の「現ページ表示までは次送りを止める」
        // ペーシングと合わさり、6 並列 off-main eager デコードの CPU/メモリ帯域競合（Intel で
        // 高品質スキャンがカクつく主因＝実測 p50 130ms）を回避して 1 枚ずつ滑らかに流れる。
        // 一方**縮小が必要な大スキャン（native > target）や回転あり**は従来どおり thumbnail（off-main で
        // 即時 DCT 縮小＋EXIF 変換）を通す — メモリ節約と、Intel での「大画像を描画時デコード＝
        // run loop 停止（G18 の“めくれない”）」の回避のため（この経路は G18 の根治を維持）。
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let nativeMax = max((props?[kCGImagePropertyPixelWidth] as? Int) ?? 0,
                            (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0)
        let wantsFullRes = maxPixelSize <= 0
        let noDownsampleNeeded = nativeMax > 0 && maxPixelSize > 0 && nativeMax <= maxPixelSize
        if orientation == 1, wantsFullRes || noDownsampleNeeded,
           let image = CGImageSourceCreateImageAtIndex(source, 0, [
               kCGImageSourceShouldCacheImmediately: true,   // 即時展開（off-main）
           ] as CFDictionary) {
            return DecodedImage(cgImage: image, pixelSize: CGSize(width: image.width, height: image.height))
        }

        // 縮小が必要 or 回転あり: thumbnail（DCT 縮小＋EXIF 変換）。maxPixelSize<=0 は縮小なし上限。
        let target = maxPixelSize > 0 ? maxPixelSize : Self.nativeResolutionSentinel
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // EXIF orientation を反映
        ] as CFDictionary) else { return nil }
        return DecodedImage(cgImage: image, pixelSize: CGSize(width: image.width, height: image.height))
    }

    /// G19: フル解像度の**遅延**デコード（Apple Silicon 用）。
    ///
    /// cooViewer 準拠モデル: ダウンサンプルも即時デコードもせず、フル解像度の**遅延** CGImage を返す。
    /// 実ピクセル展開は描画時（`ctx.draw`）に走り、AS では HW デコードで一瞬。**背景（先読み）は
    /// バイト取得＋遅延 CGImage 生成だけで軽く**、eager 縮小デコードのように「デコード済みキャッシュを
    /// 使い切ると各めくりがデコード待ちになる」閾値が生じない（G18 の AS 回帰の根治）。
    ///
    /// EXIF 向きの扱い: `CGImageSourceCreateImageAtIndex` は向きを適用しない。向き up（またはタグ無し・
    /// 漫画スキャンの大多数）は遅延のまま返す。回転/反転あり（稀）は正しさ優先で `decode(maxPixelSize:0)`
    /// （thumbnail-with-transform で向きをベイク・即時展開）にフォールバックする。
    ///
    /// - Important: この遅延経路はメインスレッド描画時にデコードが走るため、**HW デコードのある
    ///   Apple Silicon 専用**。Intel（x86_64 スライス）は `decode(maxPixelSize:)` の off-main eager を使う
    ///   （描画時デコードは Intel で run loop を止めるため）。呼び出し側で `#if arch(arm64)` 分岐する。
    public static func decodeLazy(_ data: Data) -> DecodedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        // 向き up 以外（回転/反転）は向きベイクが要るので eager フルデコードにフォールバック。
        guard orientation == 1 else { return decode(data, maxPixelSize: 0) }
        // 向き up: フル解像度の遅延 CGImage（描画時に初めてデコード）。
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: false,   // 遅延（描画時デコード）
        ] as CFDictionary) else {
            return decode(data, maxPixelSize: 0)           // 生成不能時のフォールバック
        }
        return DecodedImage(cgImage: image, pixelSize: CGSize(width: image.width, height: image.height))
    }

    /// フル解像度デコード時に thumbnail API へ渡す「縮小させない」ための上限値。
    /// 実在する画像の最大辺がこれを超えることは実運用上ない（想定: 数万 px 級のスキャン画像でも収まる）。
    private static let nativeResolutionSentinel = 1 << 16  // 65536
}
