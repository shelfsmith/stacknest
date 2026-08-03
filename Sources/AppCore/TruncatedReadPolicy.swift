// SPDX-License-Identifier: MIT
import Foundation

/// G26 最終レビュー Important #1: 「**打ち切り読みから導いた数値は DB に記録しない**」という
/// 一点だけを表す判定表。App ターゲットは `swift test` の対象外なので、判定そのものはここに
/// 純関数として置き、`AppState` / `ViewerWindowController` は結果を使うだけにする
/// （`CoverRegen` と同じ設計方針）。
///
/// 背景: 破損アーカイブは G26 から「壊れた位置まで読める本」として開くようになった。
/// このとき `pageCount` は実際より小さい値（例: 全 150 ページのうち 30）になるため、
/// 素直に DB へ書くと
///
/// - `books.pages` が 30 に縮む
/// - `ViewerModel.goTo(page:)` が保存済み `lastPage`=150 を 29 にクランプし、閉じるときに
///   その 29 が `book_viewer_state` へ書き戻される
///
/// の 2 つが同時に起き、ライブラリ上は「30/30＝読了」に見えて**読書位置が復元不能になる**。
/// ファイルを修復しても失われた位置は戻らない。そこで「壊れた読みから出た数値は一切残さない」
/// を規則とする。破損の間は DB が触られないので、修復後の次回オープンで正しい値へ収束する。
public enum TruncatedReadPolicy {
    /// `books.pages` へ書いてよい値。打ち切り読みなら nil（＝書かない）。
    /// `livePageCount <= 0` も nil（そもそも収束させる材料がない）。
    public static func pageCountToWrite(livePageCount: Int, truncated: Bool) -> Int? {
        guard !truncated, livePageCount > 0 else { return nil }
        return livePageCount
    }

    /// `book_viewer_state.last_page` へ書く値。
    ///
    /// 打ち切り読みで、書こうとしている位置が**開いた時点の保存値より手前**なら、それは
    /// `ViewerModel.goTo(page:)` のクランプで下がっただけの可能性がある。この場合は
    /// 保存済みの値をそのまま返す（＝上書きしても内容が変わらない）ことで読書位置を守る。
    ///
    /// - 打ち切りでなければ常に現在位置（従来どおり）。
    /// - 打ち切りでも前進（`currentPage >= storedLastPage`）なら現在位置。クランプは
    ///   位置を下げることしかしないので、前進はユーザー操作でしか起こらない。
    /// - 打ち切り時の「後退」はユーザー操作の可能性もあるが区別できないため、安全側
    ///   （記録しない）に倒す。ユーザーが resume シートで「最初から」を選んだ場合だけは
    ///   呼び出し側が `storedLastPage` を 0 に更新して意思表示を通す。
    public static func lastPageToPersist(currentPage: Int, storedLastPage: Int, truncated: Bool) -> Int {
        guard truncated, currentPage < storedLastPage else { return currentPage }
        return storedLastPage
    }

    /// `lastPageToPersist` の答えが `truncated` に依存するか。
    ///
    /// false のとき、`truncated` が true でも false でも結果は同じ（＝現在位置がそのまま通る）ので、
    /// 呼び出し側は**破損判定そのものを省いてよい**。サーバの `/progress` のように打ち切り判定に
    /// アーカイブ走査のコストが伴う経路で、前進書き込み（大多数）を素通しさせるために使う。
    ///
    /// この述語を policy 側に置くのは、「前進なら truncated は無関係」という判断も規則の一部で
    /// あり、呼び出し側で `if page < stored` と書き下すとそれが規則の二重定義になるため。
    /// 不変条件は `TruncatedReadPolicyTests` が総当りで固定する。
    public static func truncationAffectsLastPage(currentPage: Int, storedLastPage: Int) -> Bool {
        currentPage < storedLastPage
    }

    /// **永続化される自動分類**（`BookTypeClassifier.autoClassify`）へ渡してよいページ数。
    /// 打ち切り読みなら nil（＝ページ数に依存しない分類へフォールバックさせる）。
    ///
    /// `pageCountToWrite` と分けてあるのは 0 の扱いだけが違うため。`books.pages` は 0 を
    /// 「収束させる材料が無い」として書かないが、分類では「0 ページの本」という事実自体は
    /// 打ち切りではなく正しい入力なので素通しする（従来どおり薄い本に分類される）。
    public static func pageCountForClassification(livePageCount: Int, truncated: Bool) -> Int? {
        truncated ? nil : livePageCount
    }
}
