// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// G25c: library_settings の原子的 compare-and-set。
/// #8 の遅延ハッシュ移行は「検証したハッシュが今も DB 上の値である」ときだけ書き戻さなければならない。
/// メモリ上の値と比較しても、**別プロセスが DB を書き換えていた場合を検出できない**ため DB 層で判定する。
@Suite("library_settings の原子的 compare-and-set")
struct LibrarySettingCASTests {
    private func makeDB(_ tag: String) throws -> (Database, URL) {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("setting-cas-\(tag)-\(UUID()).sqlite")
        let db = try Database.openFile(at: tmpURL, mode: .createOrReplace)
        try db.migrate()
        return (db, tmpURL)
    }

    @Test("期待値と一致すれば更新して true")
    func updatesWhenExpectedMatches() throws {
        let (db, url) = try makeDB("match")
        defer { try? FileManager.default.removeItem(at: url) }
        try db.setLibrarySetting(key: "lock_password_hash", value: "H1")

        let ok = try db.compareAndSetLibrarySetting(key: "lock_password_hash", expected: "H1", newValue: "PBKDF2_H1")
        #expect(ok == true)
        #expect(try db.getLibrarySetting(key: "lock_password_hash") == "PBKDF2_H1")
    }

    @Test("★別接続が書き換えていたら更新せず false（巻き戻しを防ぐ）")
    func refusesWhenAnotherConnectionChangedIt() throws {
        let (db, url) = try makeDB("race")
        defer { try? FileManager.default.removeItem(at: url) }
        try db.setLibrarySetting(key: "lock_password_hash", value: "H1")

        // 別プロセス相当: 同じファイルを別接続で開き、外部から新パスワード H2 を設定する。
        let other = try Database.openExisting(at: url)
        try other.setLibrarySetting(key: "lock_password_hash", value: "H2")

        // 旧シートが H1 の検証を通した後の書き戻し。H2 を巻き戻してはならない。
        let ok = try db.compareAndSetLibrarySetting(key: "lock_password_hash", expected: "H1", newValue: "PBKDF2_H1")
        #expect(ok == false)
        #expect(try db.getLibrarySetting(key: "lock_password_hash") == "H2")
    }

    @Test("キーが存在しなければ更新せず false（施錠解除済み）")
    func refusesWhenKeyMissing() throws {
        let (db, url) = try makeDB("missing")
        defer { try? FileManager.default.removeItem(at: url) }
        let ok = try db.compareAndSetLibrarySetting(key: "lock_password_hash", expected: "H1", newValue: "PBKDF2_H1")
        #expect(ok == false)
        #expect(try db.getLibrarySetting(key: "lock_password_hash") == nil)
    }

    @Test("他のキーを巻き込まない")
    func doesNotTouchOtherKeys() throws {
        let (db, url) = try makeDB("scope")
        defer { try? FileManager.default.removeItem(at: url) }
        try db.setLibrarySetting(key: "lock_password_hash", value: "H1")
        try db.setLibrarySetting(key: "lock_password_salt", value: "S1")

        _ = try db.compareAndSetLibrarySetting(key: "lock_password_hash", expected: "H1", newValue: "PBKDF2_H1")
        #expect(try db.getLibrarySetting(key: "lock_password_salt") == "S1")
    }
}
