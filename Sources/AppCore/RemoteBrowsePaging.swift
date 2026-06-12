// SPDX-License-Identifier: MIT
import Foundation

/// リモートブラウズの表示モード（排他 2 択）。
public enum RemoteScrollMode: String, Codable, Sendable, CaseIterable {
    case paged
    case infinite
}

/// paged の総ページ数（per<=0 と total=0 は 1）。
public func remoteTotalPages(total: Int, per: Int) -> Int {
    guard per > 0 else { return 1 }
    return max(1, Int((Double(total) / Double(per)).rounded(.up)))
}

/// infinite で次チャンクを取りに行くべきか（現在表示件数 < 総件数）。
public func remoteNeedsNextChunk(loadedCount: Int, total: Int) -> Bool {
    loadedCount < total
}

/// paged の per をユーザー範囲 20...500 にクランプ。
public func clampRemotePerPage(_ n: Int) -> Int {
    min(500, max(20, n))
}

/// 表示モード＋per のグローバル設定（UserDefaults 平文・全リモート window 共通）。
public struct RemoteBrowsePreferences: @unchecked Sendable {
    private let defaults: UserDefaults
    private static let modeKey = "remote_browse_scroll_mode"
    private static let perKey = "remote_browse_per_page"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var scrollMode: RemoteScrollMode {
        get { defaults.string(forKey: Self.modeKey).flatMap(RemoteScrollMode.init(rawValue:)) ?? .paged }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.modeKey) }
    }

    public var perPageSize: Int {
        get {
            let v = defaults.object(forKey: Self.perKey) as? Int ?? 100
            return clampRemotePerPage(v)
        }
        nonmutating set { defaults.set(clampRemotePerPage(newValue), forKey: Self.perKey) }
    }
}
