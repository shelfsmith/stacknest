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
            // G25c: 照合したのは**開始時に読んだスナップショット** `hash` であって、現行の値とは限らない。
            // 照合中に管理者や別経路がパスワードを変更していた場合、旧パスワードでの成功を返すと
            // **無効になったパスワードに library token を発行する**（認証の fail-open）。
            // 成功を返す前に「照合した hash が今も現行である」ことを確かめる。
            if let upgraded {
                // 移行を試みる。CAS 成功＝照合した hash が現行だった証拠なので、それで確認を兼ねる。
                if (try? db.compareAndSetLibrarySetting(
                        key: "lock_password_hash", expected: hash, newValue: upgraded)) == true {
                    return true
                }
                // 拒否（差し替えられた）か書き込み失敗。下の再読みでどちらかを切り分ける
                // ＝書き込み失敗なら現行値は hash のままなので解錠は認める（移行は次回に再試行）。
            }
            return (try? db.getLibrarySetting(key: "lock_password_hash")) == hash
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
