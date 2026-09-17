// SPDX-License-Identifier: MIT

/// G54-S3: ページ送りの演出。画像ビューアと EPUB（Washi の `EPUBPageTurnStyle`）で共有する値型。
/// 「なし」を `none` にしないのは、`Optional.none` と取り違える比較や `?? .none` の曖昧さを避けるため。
public enum PageTurnStyleValue: String, Codable, Sendable, CaseIterable {
    case off, fade, slide
}
