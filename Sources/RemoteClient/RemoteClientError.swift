// SPDX-License-Identifier: MIT
import Foundation

public enum RemoteClientError: Error, Equatable, Sendable {
    case offline
    case timeout
    case unauthorized     // 401
    case forbidden        // 403（権限不足 / 誤パスワード）
    /// G25d: 403 のうち**施錠ゲートによる拒否**。保持しているライブラリトークンが失効したことを意味する
    /// （パスワード変更・施錠解除・TTL 切れ）。呼出側はトークンを捨てて解錠フォームを出し直すこと。
    /// 権限不足の 403 と区別するのは、後者でトークンを捨てると単に権限が無いだけの利用者を
    /// 解錠フォームへ飛ばしてしまうため。
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
}
