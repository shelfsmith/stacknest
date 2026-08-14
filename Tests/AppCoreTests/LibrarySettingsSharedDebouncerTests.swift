// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryStore

/// G36 Codex レビュー P2: 複数のリモートウィンドウが**同じ settings.db** を指す `LibrarySettings`
/// を別々に持つ（`RemoteLibraryWindowContainer.make()` の意図的な設計 ―― ラベルが
/// per-window のため）。G36 ③ で `columnWidths` / `gridItemSize` / `windowFrame` の書き込みを
/// デバウンスしたとき、各インスタンスが**別々の `SettingsWriteDebouncer`** を持つと、
/// この 3 キーに限り「同じ DB への書き込みなのにデバウンサだけが分かれている」状態になる。
///
/// 結果: デバウンス間隔内にウィンドウ A → B の順で操作しても、ディスクへ着地する順序は
/// **schedule() が呼ばれた順ではなく flush()（＝タイマー発火や `registry.allObjects` の
/// 列挙）が呼ばれた順**で決まってしまう。G36 以前は同期書き込みだったので「書き込み順 = 操作順」
/// が保証されていたが、これは G36 が持ち込んだ退行（修正前は下記のテストと同じロジックで
/// 実際に FAIL することを確認済み ―― `LibrarySettings(database: db)` を2回呼んだだけの別々の
/// デバウンサで、逆順 flush すると古い値が残ることを実測した。詳細は
/// `.superpowers/sdd/2026-08-14-phase-g36/codex-p2-report.md` の実行ログを参照）。
///
/// 修正: `LibrarySettings.init(database:writeDebouncer:)` に共有デバウンサを注入できるようにし、
/// `RemoteLibrarySettingsProvider` が全リモートウィンドウで 1 つのデバウンサを共有するようにした。
/// 同じキー("columnWidths"等)への `schedule` が coalescing され、flush の呼び出し順に関係なく
/// 「最後に schedule された値」だけが書かれる ―― つまりユーザー操作順が復活する。
/// これらのテストはその修正後の挙動を恒久的に守る回帰テスト。
@Suite("LibrarySettings: 同じ DB を指す複数インスタンスの書き込み順序（共有デバウンサ）")
struct LibrarySettingsSharedDebouncerTests {

    private func setupFileBackedDB() throws -> (db: Database, url: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g36-p2-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("settings.db")
        let db = try Database.openFile(at: dbURL, mode: .createOrFail)
        try db.migrate()
        return (db, dbURL)
    }

    /// `LibrarySettings.init(database:writeDebouncer:)` に共有デバウンサを注入すると、
    /// 同じキー("columnWidths")への `schedule` が coalescing され、flush の呼び出し順に関係なく
    /// 「最後に schedule された値」だけが書かれる ―― つまりユーザー操作順が復活する。
    @Test("共有デバウンサを注入すると flush 順序に関係なく操作順が保たれる")
    @MainActor
    func sharedDebouncerPreservesOperationOrderRegardlessOfFlushOrder() throws {
        let (db, dbURL) = try setupFileBackedDB()
        defer { db.close() }

        let shared = SettingsWriteDebouncer()
        let windowA = try LibrarySettings(database: db, writeDebouncer: shared)
        let windowB = try LibrarySettings(database: db, writeDebouncer: shared)

        windowA.columnWidths = ["title": 100.0]
        windowB.columnWidths = ["title": 200.0]

        // 逆順で flush してもよい ―― 共有デバウンサでは同じ内部辞書を指しているので、
        // どちらから flush() を呼んでも「最後に schedule された 1 件」が実行されるだけ。
        windowB.flushPendingWrites()
        windowA.flushPendingWrites()

        let reopened = try Database.openExisting(at: dbURL)
        defer { reopened.close() }
        let raw = try #require(try reopened.getLibrarySetting(key: "columnWidths"))
        let decoded = try JSONDecoder().decode([String: Double].self, from: Data(raw.utf8))
        #expect(decoded["title"] == 200.0)
    }

    /// 逆順（B が先に操作、A が後）でも同じく最後の操作が勝つことを確認する
    /// （coalescing が「schedule 呼び出し順」で決まっており、flush 順や個体差に依存しないことの補強）。
    @Test("共有デバウンサ: 逆の操作順でも最後の操作が勝つ")
    @MainActor
    func sharedDebouncerHonorsLatestScheduleRegardlessOfWindow() throws {
        let (db, dbURL) = try setupFileBackedDB()
        defer { db.close() }

        let shared = SettingsWriteDebouncer()
        let windowA = try LibrarySettings(database: db, writeDebouncer: shared)
        let windowB = try LibrarySettings(database: db, writeDebouncer: shared)

        windowB.columnWidths = ["title": 200.0]
        windowA.columnWidths = ["title": 300.0]  // A が最後の操作

        windowA.flushPendingWrites()

        let reopened = try Database.openExisting(at: dbURL)
        defer { reopened.close() }
        let raw = try #require(try reopened.getLibrarySetting(key: "columnWidths"))
        let decoded = try JSONDecoder().decode([String: Double].self, from: Data(raw.utf8))
        #expect(decoded["title"] == 300.0)
    }

    /// ローカル庫の挙動は変えない: `LibrarySettings(database:)`（`writeDebouncer` 省略）で
    /// 作った 2 インスタンスは今まで通り**別々の**デバウンサを持ち、coalescing は効かない
    /// （flush 順次第で結果が変わりうる）。これは退行ではなくローカル庫の設計そのもの
    /// （庫ごとに別 DB なので、そもそも同じキーを取り合う場面が無い）。
    /// ここでは「デフォルト引数は注入しない限り従来どおり独立している」ことだけを確認する。
    @Test("デフォルト引数（writeDebouncer 省略）は依然として独立したデバウンサを作る")
    @MainActor
    func defaultInitStillCreatesIndependentDebouncers() throws {
        let (db, dbURL) = try setupFileBackedDB()
        defer { db.close() }

        let windowA = try LibrarySettings(database: db)
        let windowB = try LibrarySettings(database: db)

        windowA.columnWidths = ["title": 100.0]
        windowB.columnWidths = ["title": 200.0]

        // B を先に flush しても、A の保留書き込みは A 自身のデバウンサにまだ残っている。
        windowB.flushPendingWrites()
        let midway = try Database.openExisting(at: dbURL)
        let midRaw = try #require(try midway.getLibrarySetting(key: "columnWidths"))
        midway.close()
        let midDecoded = try JSONDecoder().decode([String: Double].self, from: Data(midRaw.utf8))
        #expect(midDecoded["title"] == 200.0, "B 自身の flush 直後は B の値が見えるはず")

        // A を flush すると、A 自身のデバウンサに残っていた古い値が別々に書かれる
        // （coalescing が効かないことの確認 ―― デフォルト引数の独立性そのもの）。
        windowA.flushPendingWrites()
        let reopened = try Database.openExisting(at: dbURL)
        defer { reopened.close() }
        let raw = try #require(try reopened.getLibrarySetting(key: "columnWidths"))
        let decoded = try JSONDecoder().decode([String: Double].self, from: Data(raw.utf8))
        #expect(decoded["title"] == 100.0, "独立したデバウンサでは A の保留書き込みが後から B を上書きする")
    }
}
