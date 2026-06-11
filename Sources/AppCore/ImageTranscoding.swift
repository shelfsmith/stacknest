// SPDX-License-Identifier: MIT
import Foundation

/// 画像バイト列の縮小・再圧縮の抽象（4.1c）。
/// LibraryServer はこの protocol 経由で注入を受ける（ImageIO 直接 import を避ける）。
public protocol ImageTranscoding: Sendable {
    /// 画像を最大幅 `maxWidth` px に縮小して返す。
    /// 縮小不要（元幅 ≤ maxWidth）・非画像・失敗時は元データをそのまま返す（決して throw しない）。
    func scaled(_ data: Data, maxWidth: Int) -> Data
}

/// 縮小しない既定実装（Docker v1・テスト用）。
public struct PassthroughTranscoder: ImageTranscoding {
    public init() {}
    public func scaled(_ data: Data, maxWidth: Int) -> Data { data }
}
