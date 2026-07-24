// SPDX-License-Identifier: MIT
import Foundation

public enum RemoteClientError: Error, Equatable, Sendable {
    case offline
    case timeout
    case unauthorized     // 401
    case forbidden        // 403（未 unlock / 誤パスワード）
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
}
