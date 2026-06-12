// SPDX-License-Identifier: MIT
import Foundation

public enum RemoteClientError: Error, Equatable, Sendable {
    case offline
    case timeout
    case unauthorized     // 401
    case forbidden        // 403（未 unlock / 誤パスワード）
    case notFound         // 404
    case server(Int)
    case decoding
    case badResponse
}
