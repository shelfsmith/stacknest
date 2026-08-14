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
/// (`registry`) を持たせ、`flushAll()` で一括 flush できるようにした。
///
/// ## G36 Codex 再レビュー Minor #1 での変更
///
/// 当初 `flushAll()` は `registry.allObjects` を走査して個々の `flushPendingWrites()` を呼んで
/// いたが、その後の P2 修正で全リモートウィンドウが `sharedWriteDebouncer` を共有するように
/// なったため、`flushAll()` は今**`sharedWriteDebouncer.flush()` を直接呼ぶ**実装に変わった
/// （registry を経由しなくても、共有デバウンサに乗っている保留中の書き込みは全部まとめて
/// 着地する。むしろ registry 経由だと「最後の強参照が保留を残したまま解放されて registry
/// から消えた」ケースを取りこぼす穴があった）。
///
/// このテストはそれに合わせ、**production の `make()` と同じ配線**
/// （`RemoteLibrarySettingsProvider.sharedWriteDebouncer` を注入した `LibrarySettings`）を
/// 一時ファイルの settings.db で再現し、`flushAll()` が実際にディスクへ届くことを検証する。
///
/// ## なぜ `make()` を使わないか
///
/// `RemoteLibrarySettingsProvider.make()` はアプリサポート配下の実ファイル
/// （`~/Library/Application Support/StackNest/RemoteSettings/settings.db` ―― 実ユーザーの
/// 本物のリモート設定 DB）を直接開く。テストからここを経由すると実データを汚しかねないため、
/// 一時ファイルで作った `LibrarySettings` に `sharedWriteDebouncer`（本物のインスタンス）だけを
/// 注入し、DB は隔離したまま `flushAll()` の効果を見る。
@Suite("RemoteLibrarySettingsProvider.flushAll（G36 ③ Task 7 / Codex 再レビュー Minor #1）")
@MainActor
struct RemoteSettingsFlushOnTerminateTests {

    /// 実ファイルの settings.db を 1 つ用意する（`Database.openFile` → `migrate`）。
    /// バックアップ検証と同じ理由で in-memory ではなく実ファイルにする ―― ここでは
    /// 「flush 後に DB を閉じ、独立に開き直して読む」ことで持続性そのものを確かめるため、
    /// in-memory では close 後に内容が消えてしまい検証にならない。
    ///
    /// `writeDebouncer` は既定では独立した新規インスタンス（テストの隔離を優先）。
    /// `flushAll()` を実際に検証したいテストだけ `RemoteLibrarySettingsProvider.sharedWriteDebouncer`
    /// を明示的に渡す（production の `make()` と同じ配線を再現するため）。
    private func makeFileBackedSettings(
        writeDebouncer: SettingsWriteDebouncer = SettingsWriteDebouncer()
    ) throws -> (settings: LibrarySettings, db: Database, dbURL: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g36-remote-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("settings.db")
        let db = try Database.openFile(at: dbURL, mode: .createOrFail)
        try db.migrate()
        let settings = try LibrarySettings(database: db, writeDebouncer: writeDebouncer)
        return (settings, db, dbURL)
    }

    private func readColumnWidths(at dbURL: URL) throws -> [String: Double]? {
        let db = try Database.openExisting(at: dbURL)
        defer { db.close() }
        guard let raw = try db.getLibrarySetting(key: "columnWidths") else { return nil }
        return try JSONDecoder().decode([String: Double].self, from: Data(raw.utf8))
    }

    // MARK: - ★ 本命: 共有デバウンサに乗った保留中の書き込みへ flushAll() が実際に届く

    @Test("保留中の columnWidths が flushAll() でディスクへ確定する（sharedWriteDebouncer 経由）")
    func flushAllPersistsPendingColumnWidths() throws {
        let (settings, db, dbURL) = try makeFileBackedSettings(
            writeDebouncer: RemoteLibrarySettingsProvider.sharedWriteDebouncer)

        // 500ms のデバウンス中はまだディスクに無い状態を作る（ローカル側の
        // CloseBundleFlushOrderTests と同じセットアップ）。
        settings.columnWidths = ["title": 314.0]

        RemoteLibrarySettingsProvider.flushAll()
        db.close()   // 独立に開き直して読むため、まず自分の参照を閉じる

        let decoded = try #require(try readColumnWidths(at: dbURL),
                                    "flushAll() が届いていれば columnWidths キーがディスクに存在するはず")
        #expect(decoded["title"] == 314.0)
    }

    // MARK: - 複数のリモートウィンドウ（複数キー）が両方とも届く

    /// レビューで指摘された「リモートウィンドウが複数ある場合に全部に届くか」への回答。
    ///
    /// production のトポロジーに合わせ、2 つの `LibrarySettings`（= 2 つのウィンドウ）が
    /// **同じ settings.db・同じ sharedWriteDebouncer** を共有する構成にする（G36 Codex P2 で
    /// 実際にそうなった）。片方は `columnWidths`、もう片方は `gridItemSize` を変更する ――
    /// 同じキーにすると coalescing で片方が消えるのは意図した仕様（P2 修正の本旨）なので、
    /// ここでは「異なる複数のキーがどちらも取りこぼされずに flush される」ことを確かめる。
    @Test("複数のリモートウィンドウの異なるキーが両方とも flushAll() で確定する")
    func flushAllReachesEveryPendingKey() throws {
        let (windowA, db, dbURL) = try makeFileBackedSettings(
            writeDebouncer: RemoteLibrarySettingsProvider.sharedWriteDebouncer)
        // 同じ db・同じ sharedWriteDebouncer を指す 2 本目の LibrarySettings
        // （= 2 つ目のリモートウィンドウを模す。`RemoteLibraryWindowContainer.make()` が
        // ウィンドウごとに新しいインスタンスを返すのと同じ形）。
        let windowB = try LibrarySettings(database: db, writeDebouncer: RemoteLibrarySettingsProvider.sharedWriteDebouncer)

        windowA.columnWidths = ["title": 111.0]
        windowB.gridItemSize = 222.0

        RemoteLibrarySettingsProvider.flushAll()
        db.close()

        let reopened = try Database.openExisting(at: dbURL)
        defer { reopened.close() }
        let widthsRaw = try #require(try reopened.getLibrarySetting(key: "columnWidths"))
        let widths = try JSONDecoder().decode([String: Double].self, from: Data(widthsRaw.utf8))
        #expect(widths["title"] == 111.0)
        let gridRaw = try #require(try reopened.getLibrarySetting(key: "grid_item_size"))
        #expect(Double(gridRaw) == 222.0)
    }

    // MARK: - flush していなければディスクに無い（デバウンスが実際に効いていることの前提確認）

    /// flushAll() を呼ばずに db を閉じた場合、デバウンス中の書き込みは
    /// （タイマが発火する前なら）ディスクに残らない。上 2 本が「常に true」を検査している
    /// わけではないことの裏付け ―― 500ms のタイマより十分速く db.close() まで到達することを
    /// 前提にしているので、フレークを避けるため待たずに即 close する。
    /// `flushAll()` を呼ばないテストなので、他テストとの隔離を優先し既定の独立デバウンサを使う
    /// （`sharedWriteDebouncer` を使う必然性が無い）。
    @Test("flushAll() を呼ばずに閉じるとデバウンス中の書き込みは残らない")
    func withoutFlushThePendingWriteIsLost() throws {
        let (settings, db, dbURL) = try makeFileBackedSettings()

        settings.columnWidths = ["title": 999.0]
        db.close()   // flushAll() を呼ばない

        let decoded = try readColumnWidths(at: dbURL)
        #expect(decoded == nil, "flush していない保留中の書き込みはディスクに残らないはず")
    }
}
