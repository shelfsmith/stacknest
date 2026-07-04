// SPDX-License-Identifier: MIT
import Foundation

/// リモートキャッシュの上限/TTL（app-global・UserDefaults）。無制限=0 / TTL 無効=0。
enum RemoteCacheSettings {
    static let limitKey = "remote_cache_limit_bytes"
    static let maxAgeKey = "remote_cache_max_age_seconds"
    static let defaultLimit: Int64 = 2 * 1024 * 1024 * 1024      // 2GB
    static let defaultMaxAge: Int64 = 30 * 24 * 3600            // 30日

    static func limitBytes(_ d: UserDefaults = .standard) -> Int64 {
        d.object(forKey: limitKey) == nil ? defaultLimit : Int64(d.integer(forKey: limitKey))
    }
    static func setLimitBytes(_ v: Int64, _ d: UserDefaults = .standard) { d.set(Int(v), forKey: limitKey) }
    static func maxAgeSeconds(_ d: UserDefaults = .standard) -> Int64 {
        d.object(forKey: maxAgeKey) == nil ? defaultMaxAge : Int64(d.integer(forKey: maxAgeKey))
    }
    static func setMaxAgeSeconds(_ v: Int64, _ d: UserDefaults = .standard) { d.set(Int(v), forKey: maxAgeKey) }
}
