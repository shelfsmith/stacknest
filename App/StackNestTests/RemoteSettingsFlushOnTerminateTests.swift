// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
import LibraryStore
@testable import StackNest

/// G36 ③ Task 7 レビュー Critical 1: リモート庫の `LibrarySettings` は `AppState` を経由しない
/// （`RemoteLibraryWindowContainer` の `@State` にしか保持されない）ため、
/// `applicationWillTerminate` の AppState 経由 flush ループが届かず、リモート庫でドラッグした
/// 直後 500ms 以内に ⌘Q すると列幅・グリッドサイズが失われる退行があった。
///
/// `RemoteLibrarySettingsProvider` に `AppStateRegistry` と同じ流儀の弱参照レジストリ
/// (`registry`) を持たせ、`flushAll()` で一括 flush できるようにした。このテストはその
/// `flushAll()` が実際に登録済みインスタンスへ届くことを検証する。
///
/// ## なぜ `make()` を使わないか
///
/// `RemoteLibrarySettingsProvider.make()` はアプリサポート配下の実ファイル
/// （`~/Library/Application Support/StackNest/RemoteSettings/settings.db` ―― 実ユーザーの
/// 本物のリモート設定 DB）を直接開く。テストからここを経由すると実データを汚しかねないため、
/// 一時ファイルで作った `LibrarySettings` を `RemoteLibrarySettingsProvider.registry` へ
/// 直接登録し、`flushAll()` の効果だけを見る。
@Suite("RemoteLibrarySettingsProvider.flushAll（G36 ③ Task 7 レビュー Critical 1）")
@MainActor
struct RemoteSettingsFlushOnTerminateTests {

    /// 実ファイルの settings.db を 1 つ用意する（`Database.openFile` → `migrate`）。
    /// バックアップ検証と同じ理由で in-memory ではなく実ファイルにする ―― ここでは
    /// 「flush 後に DB を閉じ、独立に開き直して読む」ことで持続性そのものを確かめるため、
    /// in-memory では close 後に内容が消えてしまい検証にならない。
    private func makeFileBackedSettings() throws -> (settings: LibrarySettings, db: Database, dbURL: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g36-remote-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("settings.db")
        let db = try Database.openFile(at: dbURL, mode: .createOrFail)
        try db.migrate()
        let settings = try LibrarySettings(database: db)
        return (settings, db, dbURL)
    }

    private func readColumnWidths(at dbURL: URL) throws -> [String: Double]? {
        let db = try Database.openExisting(at: dbURL)
        defer { db.close() }
        guard let raw = try db.getLibrarySetting(key: "columnWidths") else { return nil }
        return try JSONDecoder().decode([String: Double].self, from: Data(raw.utf8))
    }

    // MARK: - ★ 本命: 登録済みインスタンスへ flushAll() が実際に届く

    @Test("登録済みリモート設定の columnWidths が flushAll() でディスクへ確定する")
    func flushAllPersistsPendingColumnWidths() throws {
        let (settings, db, dbURL) = try makeFileBackedSettings()
        RemoteLibrarySettingsProvider.registry.add(settings)

        // 500ms のデバウンス中はまだディスクに無い状態を作る（ローカル側の
        // CloseBundleFlushOrderTests と同じセットアップ）。
        settings.columnWidths = ["title": 314.0]

        RemoteLibrarySettingsProvider.flushAll()
        db.close()   // 独立に開き直して読むため、まず自分の参照を閉じる

        let decoded = try #require(try readColumnWidths(at: dbURL),
                                    "flushAll() が届いていれば columnWidths キーがディスクに存在するはず")
        #expect(decoded["title"] == 314.0)
    }

    // MARK: - 複数のリモートウィンドウ全部に届く

    /// レビューで指摘された「リモートウィンドウが複数ある場合に全部に届くか」への回答。
    /// `flushAll()` は登録済みの全インスタンスを走査するので、2 つの別ウィンドウ（別 settings.db）
    /// を模して両方が確定することを確かめる。
    @Test("複数のリモートウィンドウの設定が両方とも flushAll() で確定する")
    func flushAllReachesEveryRegisteredWindow() throws {
        let (settingsA, dbA, dbURLA) = try makeFileBackedSettings()
        let (settingsB, dbB, dbURLB) = try makeFileBackedSettings()
        RemoteLibrarySettingsProvider.registry.add(settingsA)
        RemoteLibrarySettingsProvider.registry.add(settingsB)

        settingsA.columnWidths = ["title": 111.0]
        settingsB.columnWidths = ["title": 222.0]

        RemoteLibrarySettingsProvider.flushAll()
        dbA.close()
        dbB.close()

        let decodedA = try #require(try readColumnWidths(at: dbURLA))
        let decodedB = try #require(try readColumnWidths(at: dbURLB))
        #expect(decodedA["title"] == 111.0)
        #expect(decodedB["title"] == 222.0)
    }

    // MARK: - flush していなければディスクに無い（デバウンスが実際に効いていることの前提確認）

    /// flushAll() を呼ばずに db を閉じた場合、デバウンス中の書き込みは
    /// （タイマが発火する前なら）ディスクに残らない。上 2 本が「常に true」を検査している
    /// わけではないことの裏付け ―― 500ms のタイマより十分速く db.close() まで到達することを
    /// 前提にしているので、フレークを避けるため待たずに即 close する。
    @Test("flushAll() を呼ばずに閉じるとデバウンス中の書き込みは残らない")
    func withoutFlushThePendingWriteIsLost() throws {
        let (settings, db, dbURL) = try makeFileBackedSettings()
        RemoteLibrarySettingsProvider.registry.add(settings)

        settings.columnWidths = ["title": 999.0]
        db.close()   // flushAll() を呼ばない

        let decoded = try readColumnWidths(at: dbURL)
        #expect(decoded == nil, "flush していない保留中の書き込みはディスクに残らないはず")
    }
}
