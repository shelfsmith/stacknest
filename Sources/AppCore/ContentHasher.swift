// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit

/// ファイルを定メモリでストリーミング読みして SHA-256（hex 小文字）を返す。
/// 重複検出（A20/B11）の content_hash 計算に使う。大きなアーカイブ/動画でも定メモリ。
public enum ContentHasher {
    public static func sha256(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
