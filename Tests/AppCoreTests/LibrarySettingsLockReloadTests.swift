// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
@testable import LibraryStore

/// G24: 外部（CLI / MCP / リモートの lock エンドポイント）が DB のロック設定を直接書き換えたとき、
/// メモリ上の `LibrarySettings` へ反映する。
///
/// これが無かったため、`stacknest-cli lock set` で施錠しても稼働中の App は `lockPasswordHash` を
/// 古いまま（nil）保持し、`AppStateLibraryDataSource.servedLibraries()` が `isLocked: false` を返し続けた。
/// 結果として**施錠したつもりの庫が配信上は無施錠**になっていた（`GET /libraries` の `locked` も false）。
@MainActor
@Suite("LibrarySettings lock reload")
struct LibrarySettingsLockReloadTests {

    /// 外部が施錠した（hash/salt を書いた）→ メモリへ反映される。
    @Test func reloadLockSettingsPicksUpExternalLock() throws {
        let db = try Database.openInMemory(); try db.migrate()
        let s = try LibrarySettings(database: db)
        #expect(s.lockPasswordHash == nil)

        try db.setLibrarySetting(key: "lock_password_salt", value: "abcdef1234567890abcdef1234567890")
        try db.setLibrarySetting(key: "lock_password_hash", value: "pbkdf2$210000$\(String(repeating: "a", count: 64))")
        s.reloadLockSettings()

        #expect(s.lockPasswordHash?.hasPrefix("pbkdf2$") == true)
        #expect(s.lockPasswordSalt == "abcdef1234567890abcdef1234567890")
    }

    /// **削除の反映が要点**: 外部がロックを解除した（hash/salt を消した）→ メモリも nil に戻る。
    /// 他の reload メソッドは「値があれば代入」で済むが、ロックは nil への変化を反映しないと
    /// 解除が効かない（施錠されたままに見える）。
    @Test func reloadLockSettingsPicksUpExternalUnlock() throws {
        let db = try Database.openInMemory(); try db.migrate()
        try db.setLibrarySetting(key: "lock_password_salt", value: "0011223344556677")
        try db.setLibrarySetting(key: "lock_password_hash", value: "deadbeef")
        let s = try LibrarySettings(database: db)
        #expect(s.lockPasswordHash != nil)

        try db.deleteLibrarySetting(key: "lock_password_hash")
        try db.deleteLibrarySetting(key: "lock_password_salt")
        s.reloadLockSettings()

        #expect(s.lockPasswordHash == nil)
        #expect(s.lockPasswordSalt == nil)
    }

    /// 再読み込みで DB へ書き戻さない（didSet の永続化が無限ループや不要な書き込みを起こさない）。
    @Test func reloadLockSettingsDoesNotRewriteDatabase() throws {
        let db = try Database.openInMemory(); try db.migrate()
        let s = try LibrarySettings(database: db)
        try db.setLibrarySetting(key: "lock_password_hash", value: "external-value")
        s.reloadLockSettings()
        // reload 後も DB の値は外部が書いたまま（メモリ由来の値で上書きされていない）。
        #expect((try? db.getLibrarySetting(key: "lock_password_hash")) == "external-value")
        #expect(s.lockPasswordHash == "external-value")
    }

    /// 施錠 → 解除 → 再施錠を続けて反映できる。
    @Test func reloadLockSettingsHandlesRepeatedChanges() throws {
        let db = try Database.openInMemory(); try db.migrate()
        let s = try LibrarySettings(database: db)

        try db.setLibrarySetting(key: "lock_password_hash", value: "h1")
        s.reloadLockSettings()
        #expect(s.lockPasswordHash == "h1")

        try db.deleteLibrarySetting(key: "lock_password_hash")
        s.reloadLockSettings()
        #expect(s.lockPasswordHash == nil)

        try db.setLibrarySetting(key: "lock_password_hash", value: "h2")
        s.reloadLockSettings()
        #expect(s.lockPasswordHash == "h2")
    }
}
