// SPDX-License-Identifier: MIT
import Foundation

public enum RemoteClientError: Error, Equatable, Sendable {
    case offline
    case timeout
    case unauthorized     // 401
    case forbidden        // 403（権限不足 / 誤パスワード）
    case notFound         // 404
    case badRequest(String?)  // 400（サーバの詳細文言つき。例: 監視フォルダの不正パス）
    case server(Int)
    case decoding
    case badResponse
    /// G21 #4: in-flight リクエストが上位の Task キャンセルで打ち切られた（URLError.cancelled）。
    /// より新しい呼び出しに追い越されただけで、サーバ/ネットワークの異常ではない。
    case cancelled
    /// #12: サーバ応答が許容総受信量の上限を超えたため中断した（クライアント側 DoS 対策）。
    case responseTooLarge
    /// G25d: 403 のうち**施錠ゲートによる拒否**。保持しているライブラリトークンが失効したことを意味する
    /// （パスワード変更・施錠解除・TTL 切れ）。呼出側はトークンを捨てて解錠フォームを出し直すこと。
    /// 権限不足の 403 と区別するのは、後者でトークンを捨てると単に権限が無いだけの利用者を
    /// 解錠フォームへ飛ばしてしまうため。
    case libraryLocked
}

extension RemoteClientError {
    /// G25d: サーバが施錠ゲートで拒否したことを示すヘッダ。
    public static let libraryLockedHeader = "X-Library-Locked"

    /// 403 応答を、ヘッダの印を見て `libraryLocked` と `forbidden` に振り分ける。
    /// - Parameter headers: 応答ヘッダ（キーの大文字小文字は問わない）。
    public static func forbidden(headers: [String: String]) -> RemoteClientError {
        let flagged = headers.first { $0.key.caseInsensitiveCompare(libraryLockedHeader) == .orderedSame }?.value
        return flagged == "1" ? .libraryLocked : .forbidden
    }

    /// G54-S3e 最終レビュー: 巻送りの「隣接巻を尋ねる」呼び出し（`adjacentVolume`）が投げたエラーをどう扱うか。
    /// 呼び出し側（`RemoteLibraryState.resolveRemoteVolume` / `resolveRemoteEPUBSibling`）は
    /// これに従って分岐する（純粋な写像として切り出し、SPM でテストできるようにする）。
    public enum SiblingFetchOutcome: Equatable, Sendable {
        /// 錠の失効。呼び出し側が `presentRemoteError` で処理する（今までどおり）。
        case locked
        /// 「次（前）の巻なし」と同じ扱い。`.cancelled` は上位の Task 打ち切り（追い越されただけ）、
        /// `.notFound` はサーバが該当なしと答えた。
        case noSibling
        /// それ以外（オフライン・タイムアウト・サーバ障害・デコード失敗 等）。本当の失敗であり
        /// 「次の巻なし」と黙って区別なく扱わない——「開けません」で留まる。
        case unavailable
    }

    /// `SiblingFetchOutcome` へ分類する。
    public var siblingFetchOutcome: SiblingFetchOutcome {
        switch self {
        case .libraryLocked: return .locked
        case .cancelled, .notFound: return .noSibling
        default: return .unavailable
        }
    }
}
