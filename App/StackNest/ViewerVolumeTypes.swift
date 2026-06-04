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
}
