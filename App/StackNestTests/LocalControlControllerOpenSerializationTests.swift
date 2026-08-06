// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryStore
import LibraryServer
import AppCore
@testable import StackNest

/// G27b Task7 レビュー修正: `LocalControlController.openLibrary(at:)` への同時呼び出しの直列化。
///
/// **背景**: `openLibrary(at:)` はウィンドウが実際に開き `AppState` が `activeInstances` に
/// 現れるまで最大 2.5s ポーリングする（50ms 刻みで `await Task.sleep`）。その await のたびに
/// MainActor を手放すため、待っている間に同じパスへの 2 本目の open 要求が来ると、まだ
/// `activeInstances` に現れていない（＝「既に開いている」判定に引っかからない）ため
/// `openWindowAction` をもう一度呼んでしまいうる。`LocalControlController.swift` の
/// `inFlightOpens`（パス→進行中 Task の辞書）がこれを直列化する ―― 2 本目以降は
/// ウィンドウを開かず、進行中の 1 本目の Task を待って同じ結果を返す。
///
/// **なぜ fake hook 経由か**: 実 `NSWindow` は App-target テストで作るとテストホストがクラッシュ
/// する（CLAUDE.md の絶対制約・`AppEnvironmentTests.swift` に既往の 28 分ハング実績あり）ため、
/// `LocalControlController.testOpenWindowHook` に fake を注入し、`WindowBridge`/実ウィンドウを
/// 経由せずに直列化ロジックだけを検証する。fake hook は「ウィンドウが開いて `AppState` が
/// `activeInstances` に現れる」を、`Database.openInMemory()`（ファイル/UI 一切なし）で作った
/// 軽量な `AppState` を少し遅れて登録することで模する。
@Suite("LocalControlController.openLibrary concurrency (G27b Task7 review fixup)", .serialized)
struct LocalControlControllerOpenSerializationTests {

    /// 本命のテスト: 同一パスへ `async let` で 2 本の open を**並行に**投げても、
    /// ウィンドウを開く動作（fake hook の呼び出し）は 1 回しか起きず、両方とも同じ uuid を返す。
    /// 逐次呼び出しでは「既に開いている」判定だけで直列化されて見えてしまい意味がないため、
    /// 必ず `async let` で実際に concurrent に走らせる（レビュー指摘のとおり）。
    @Test @MainActor
    func concurrentOpensForSamePathTriggerOpenWindowOnlyOnce() async throws {
        // performOpen() は openWindowAction/hook を呼ぶ**前**に LibraryBundle.validate() でパスの
        // 妥当性を確認するため、テスト用パスも実在する最小バンドル（LibraryBundleCreator.createEmpty）
        // でなければならない（適当な非実在パスだと即 invalidPath で落ちて hook まで届かない）。
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-dedup-\(UUID().uuidString).stacknestlib")
        try LibraryBundleCreator.createEmpty(at: bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        var hookCallCount = 0
        // NSHashTable.weakObjects() に登録した fake AppState を生存させ続けるための強参照
        // （弱参照テーブルなので、これが無いと登録直後に解放されて活きて見えない）。
        var keepAlive: [AppState] = []

        LocalControlController.testOpenWindowHook = { url in
            hookCallCount += 1
            // 実ウィンドウが開いて AppState.openBundle() が完了するまでの非同期な遅延を模す。
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000)   // 30ms 後に「開き終わった」ことにする
                // 実バンドルの DB を開く（LibraryBundleCreator.createEmpty が migrate 済み）。
                // Database.openInMemory() は migrate されておらず library_settings テーブルが
                // 無いため LibrarySettings(database:) が即クラッシュする（実測済み）。
                let db = try! Database.openExisting(at: LibraryBundle(url: url).databaseURL)
                let settings = try! LibrarySettings(database: db)
                let fake = AppState(bundleURL: url)
                fake.librarySettings = settings
                keepAlive.append(fake)
                AppState.activeInstances.add(fake)
            }
        }
        defer {
            LocalControlController.testOpenWindowHook = nil
            for state in keepAlive { AppState.activeInstances.remove(state) }
        }

        async let first = LocalControlController.openLibrary(at: bundleURL)
        async let second = LocalControlController.openLibrary(at: bundleURL)
        let (uuid1, uuid2) = try await (first, second)

        #expect(uuid1 == uuid2, "2 本の同時 open は同じ uuid を返さなければならない")
        #expect(hookCallCount == 1, "同一パスへの同時 open はウィンドウを開く動作を 1 回だけに直列化すること")
    }

    /// 失敗経路でも in-flight エントリが残留しないこと（残留すると、以降そのパスへの open が
    /// 誤って「進行中」として扱われ、永久に待たされる/古い結果を返す事故になる）。
    /// hook が何もしない（＝ AppState が現れない）ケースはタイムアウト（2.5s）待ちが必要になるため、
    /// ここでは「タイムアウトを待たずに」検証できる形として、1 回目が失敗した**後**に
    /// 2 回目を投げてもう一度ウィンドウを開く動作が起きる（＝古い Task を掴んだままではない）ことを見る。
    @Test @MainActor
    func failedOpenDoesNotLeakInFlightEntry() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lc-dedup-fail-\(UUID().uuidString).stacknestlib")
        try LibraryBundleCreator.createEmpty(at: bundleURL)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        var hookCallCount = 0
        var keepAlive: [AppState] = []

        // 1 回目: hook はウィンドウを開いたことにはするが AppState を一切登録しない
        // → performOpen はポーリングの末にタイムアウト（LocalLibraryControlError.timeout）で失敗する。
        LocalControlController.testOpenWindowHook = { _ in hookCallCount += 1 }
        defer {
            LocalControlController.testOpenWindowHook = nil
            for state in keepAlive { AppState.activeInstances.remove(state) }
        }

        await #expect(throws: LocalLibraryControlError.self) {
            try await LocalControlController.openLibrary(at: bundleURL)
        }
        #expect(hookCallCount == 1)

        // 2 回目: 同じパスへ再度 open。in-flight エントリが残っていれば、もう一度 hook が
        // 呼ばれることは無いはず（すでに完了済み Task の結果＝同じタイムアウトを再スローするだけ）。
        // 残留していなければ、新規 Task が作られ hook がもう一度呼ばれる。今回は成功させる。
        LocalControlController.testOpenWindowHook = { url in
            hookCallCount += 1
            Task { @MainActor in
                // 実バンドルの DB を開く（LibraryBundleCreator.createEmpty が migrate 済み）。
                // Database.openInMemory() は migrate されておらず library_settings テーブルが
                // 無いため LibrarySettings(database:) が即クラッシュする（実測済み）。
                let db = try! Database.openExisting(at: LibraryBundle(url: url).databaseURL)
                let settings = try! LibrarySettings(database: db)
                let fake = AppState(bundleURL: url)
                fake.librarySettings = settings
                keepAlive.append(fake)
                AppState.activeInstances.add(fake)
            }
        }
        _ = try await LocalControlController.openLibrary(at: bundleURL)
        #expect(hookCallCount == 2, "1 回目のタイムアウト後、in-flight エントリが解放されず 2 回目が hook を呼ばないのは不合格")
    }
}
