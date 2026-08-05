// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import LibraryStore

/// G27a task 8 (Codex High #1・TOCTOU): `Database.compareAndSetLibrarySettings` /
/// `compareAndDeleteLibrarySettings` の compare-and-set 意味論そのものを検証する。
///
/// これらは `LibrarySettings.setLock`/`clearLock`（AppCore・GUI 経路）と
/// `LibraryServerCore` の POST/DELETE `/lock`（HTTP 経路）の両方が共有する、
/// ロックの salt+hash を書き換える際の唯一の書き込み口になった。
@Suite("Database.compareAndSet/DeleteLibrarySettings (G27a task 8)")
struct CompareAndSetLibrarySettingsTests {
    private func setupDB() throws -> Database {
        let db = try Database.openInMemory()
        try db.migrate()
        return db
    }

    @Test("expectedValue: nil はキー未存在を条件にし、新規作成できる")
    func nilExpectedCreatesWhenAbsent() throws {
        let db = try setupDB()
        let applied = try db.compareAndSetLibrarySettings(
            conditionKey: "k", expectedValue: nil, newValues: ["k": "v1", "k2": "v2"])
        #expect(applied)
        #expect(try db.getLibrarySetting(key: "k") == "v1")
        #expect(try db.getLibrarySetting(key: "k2") == "v2")
    }

    @Test("expectedValue: nil はキーが既に存在すると拒否し、DB を変更しない")
    func nilExpectedRejectsWhenAlreadyPresent() throws {
        let db = try setupDB()
        try db.setLibrarySetting(key: "k", value: "first")
        let applied = try db.compareAndSetLibrarySettings(
            conditionKey: "k", expectedValue: nil, newValues: ["k": "attacker"])
        #expect(!applied)
        #expect(try db.getLibrarySetting(key: "k") == "first")
    }

    @Test("一致する expectedValue は書き込みを許可する")
    func matchingExpectedAllowsWrite() throws {
        let db = try setupDB()
        try db.setLibrarySetting(key: "k", value: "old")
        let applied = try db.compareAndSetLibrarySettings(
            conditionKey: "k", expectedValue: "old", newValues: ["k": "new", "sibling": "s"])
        #expect(applied)
        #expect(try db.getLibrarySetting(key: "k") == "new")
        #expect(try db.getLibrarySetting(key: "sibling") == "s")
    }

    /// 核心シナリオ: 検証に使った expectedValue が既に古い（第三者が変更済み）状態での書き込みは
    /// 拒否され、**DB は第三者の変更のまま**残る（攻撃者の値にも呼び出し元の元の値にも変わらない）。
    @Test("不一致の expectedValue は拒否され、DB は第三者の変更のまま残る")
    func staleExpectedRejectsAndLeavesConcurrentValueIntact() throws {
        let db = try setupDB()
        try db.setLibrarySetting(key: "k", value: "original")
        // 第三者が先に変更。
        try db.setLibrarySetting(key: "k", value: "third-party-change")

        // 攻撃者は "original" を検証したスナップショットのまま書き込みを試みる。
        let applied = try db.compareAndSetLibrarySettings(
            conditionKey: "k", expectedValue: "original", newValues: ["k": "attacker-value"])
        #expect(!applied)
        #expect(try db.getLibrarySetting(key: "k") == "third-party-change")
    }

    @Test("compareAndDeleteLibrarySettings: 一致する expectedValue で全キーを削除する")
    func matchingExpectedAllowsDelete() throws {
        let db = try setupDB()
        try db.setLibrarySetting(key: "k", value: "old")
        try db.setLibrarySetting(key: "sibling", value: "s")
        let applied = try db.compareAndDeleteLibrarySettings(
            conditionKey: "k", expectedValue: "old", keysToDelete: ["k", "sibling"])
        #expect(applied)
        #expect(try db.getLibrarySetting(key: "k") == nil)
        #expect(try db.getLibrarySetting(key: "sibling") == nil)
    }

    @Test("compareAndDeleteLibrarySettings: 不一致の expectedValue は拒否し、何も削除しない")
    func staleExpectedRejectsDeleteAndLeavesConcurrentValueIntact() throws {
        let db = try setupDB()
        try db.setLibrarySetting(key: "k", value: "original")
        try db.setLibrarySetting(key: "sibling", value: "s")
        try db.setLibrarySetting(key: "k", value: "third-party-change")

        let applied = try db.compareAndDeleteLibrarySettings(
            conditionKey: "k", expectedValue: "original", keysToDelete: ["k", "sibling"])
        #expect(!applied)
        #expect(try db.getLibrarySetting(key: "k") == "third-party-change")
        #expect(try db.getLibrarySetting(key: "sibling") == "s")
    }

    @Test("compareAndDeleteLibrarySettings: キーが既に無い場合も expectedValue 不一致として拒否する")
    func deleteRejectsWhenKeyAlreadyGone() throws {
        let db = try setupDB()
        // 一度も設定していないキーに対する削除試行 ―― 「一致しない」として安全側に倒れる。
        let applied = try db.compareAndDeleteLibrarySettings(
            conditionKey: "k", expectedValue: "whatever", keysToDelete: ["k"])
        #expect(!applied)
    }
}
