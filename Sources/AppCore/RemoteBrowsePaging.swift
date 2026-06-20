// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore

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

    // MARK: - 4.2c-7: ブラウザ状態の永続化（(serverID, libraryUUID) 単位）

    private static func browseStateKey(_ serverID: UUID, _ libraryUUID: String) -> String {
        "remote_browse_state/\(serverID.uuidString)/\(libraryUUID)"
    }

    public func browseState(serverID: UUID, libraryUUID: String) -> RemoteBrowseState? {
        guard let data = defaults.data(forKey: Self.browseStateKey(serverID, libraryUUID)) else { return nil }
        return try? JSONDecoder().decode(RemoteBrowseState.self, from: data)
    }

    public nonmutating func setBrowseState(_ s: RemoteBrowseState, serverID: UUID, libraryUUID: String) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        defaults.set(data, forKey: Self.browseStateKey(serverID, libraryUUID))
    }
}

/// 4.2c-7: リモートのサイドバー選択（AppCore へ移動して RemoteBrowseState から参照可能にする）。
/// 関連値付き enum の Codable は Swift が自動合成する。
public enum RemoteSidebarSelection: Codable, Sendable, Equatable, Hashable {
    case library
    case favorites(Int64)
    case recent
    case shelf(Int64)
    case smartShelf(Int64)
}

/// 4.2c-7: リモートブラウザの復元対象ブラウズ状態（(serverID, libraryUUID) 単位で永続化）。
public struct RemoteBrowseState: Codable, Sendable, Equatable {
    public var browserPaneState: BrowserPaneState
    public var sortKey: String
    public var ascending: Bool
    public var isGrid: Bool
    public var filterState: FilterState
    public var sidebar: RemoteSidebarSelection

    public init(browserPaneState: BrowserPaneState, sortKey: String, ascending: Bool,
                isGrid: Bool, filterState: FilterState, sidebar: RemoteSidebarSelection) {
        self.browserPaneState = browserPaneState
        self.sortKey = sortKey
        self.ascending = ascending
        self.isGrid = isGrid
        self.filterState = filterState
        self.sidebar = sidebar
    }
}

/// 4.2c-5: 続き位置の解決。サーバと offline の lastPage のうち大きい方（前進読み前提・nil=0）。
public func resolveResumePage(server: Int?, offline: Int?) -> Int {
    max(max(0, server ?? 0), max(0, offline ?? 0))
}
