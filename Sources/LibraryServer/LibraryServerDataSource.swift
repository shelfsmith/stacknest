// SPDX-License-Identifier: MIT
import Foundation
import LibraryStore
import AppCore

/// 配信対象の 1 ライブラリ。Database（GRDB 直列化）への参照を保持する。
/// Sendable 根拠: `Database` は LibraryStore 側で `@unchecked Sendable` 宣言済み
/// （可変状態は init/close のみで触れ、全アクセスは GRDB DatabaseQueue が直列化する）。
public struct ServedLibrary: Sendable {
    public let uuid: String           // library_settings の library_uuid 由来
    public let name: String           // 表示名（バンドル名）
    public let bundleURL: URL
    public let db: Database
    public let isLocked: Bool         // lock_password_hash が存在するか
    public init(uuid: String, name: String, bundleURL: URL, db: Database, isLocked: Bool) {
        self.uuid = uuid
        self.name = name
        self.bundleURL = bundleURL
        self.db = db
        self.isLocked = isLocked
    }

    /// ロック庫のパスワード照合（headless 可・LibraryLock 再利用）。
    public func verifyPassword(_ password: String) -> Bool {
        guard let hash = try? db.getLibrarySetting(key: "lock_password_hash"),
              let salt = try? db.getLibrarySetting(key: "lock_password_salt") else { return false }
        return LibraryLock.verify(password: password, saltHex: salt, against: hash)
    }
}

/// 「現在配信すべきライブラリ集合」の供給者。
/// 4.1b で AppState（開いている ∧ オプトイン済み）が実装。テストは Static 実装を使う。
public protocol LibraryServerDataSource: Sendable {
    func servedLibraries() async -> [ServedLibrary]
}

/// 固定リストのデータソース（テスト・Docker 将来用の基本実装）。
public struct StaticLibraryDataSource: LibraryServerDataSource {
    private let libraries: [ServedLibrary]
    public init(libraries: [ServedLibrary]) { self.libraries = libraries }
    public func servedLibraries() async -> [ServedLibrary] { libraries }
}
