// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore

/// App 層で解決済みの本ごと表示状態（overrides は PageLayoutOverride に変換済み）。
struct ResolvedViewerState {
    var spreadEnabled: Bool
    var coverOffset: Bool
    var lastPage: Int
    var overrides: [Int: PageLayoutOverride]
}

/// 次/前の巻ロード結果。pageCount は持たない（コントローラが content から非同期取得する）。
struct NextVolume {
    let content: BookContent
    let book: BookRow
    let state: ResolvedViewerState
    /// 4.2c-3: 巻ごとのソース識別ラベル（"オフライン"/"リモート"）。nil の場合は現在のバッジを維持する
    /// （ローカルビューア=バッジなし、オフラインビューア=常に「オフライン」のため未指定で良い）。
    var sourceLabel: String? = nil
}

/// G54-S3c: 画像ビューアの巻送りの解決結果。
enum VolumeLoad {
    /// 同じ窓で差し替える（zip・フォルダ・PDF・画像本 EPUB）。
    case swap(NextVolume)
    /// テキスト EPUB。画像ビューアでは読めない（0 ページ）ので、窓を閉じて所有者の通常の経路で EPUB の窓を開く。
    case openInEPUBReader(BookRow)
}
