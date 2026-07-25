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
    /// G23 (#8): 保存値が旧形式（生 SHA-256）だった場合は、この場で PBKDF2 形式へ書き戻す。
    /// 平文パスワードが手に入るのは解錠の瞬間だけなので、移行できるのはここしかない。
    public func verifyPassword(_ password: String) -> Bool {
        guard let hash = try? db.getLibrarySetting(key: "lock_password_hash"),
              let salt = try? db.getLibrarySetting(key: "lock_password_salt") else { return false }
        switch LibraryLock.verifyAndUpgrade(password: password, saltHex: salt, against: hash) {
        case .failed:
            return false
        case .ok(let upgraded):
            if let upgraded {
                // 移行の失敗は解錠を妨げない（次回の解錠でまた試みる）。
                try? db.setLibrarySetting(key: "lock_password_hash", value: upgraded)
            }
            return true
        }
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
