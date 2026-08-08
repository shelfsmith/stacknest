// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppCore
@testable import StackNest

/// App テストハーネスのハング対策（`AppEnvironment.isRunningUnitTests`）のテスト。
///
/// **このテストが存在する理由**: App テストターゲットは `StackNest.app` 本体をテストホストとして
/// 起動するため、通常起動と同じ経路で起動時のライブラリ復元が動く。そこでモーダルが出ると
/// 閉じる者がいないためテストが永久に停止する（2026-07-31 に 28 分ハングを実測。停止位置は
/// `LibraryWindowContainer.confirmForceOpen` → `NSApplication.runModalForWindow:`）。
///
/// 対策として起動時復元と `confirmForceOpen` を `AppEnvironment.isRunningUnitTests` で
/// 抑止したが、**この判定が偽になればガードは丸ごと死んだコードになり、ハングは黙って戻る**。
/// 判定機構そのものがこの修正の急所なので、ここで固定する。
///
/// **このテストが落ちたら**: `XCTestConfigurationFilePath` が設定されない実行形態に変わったか、
/// テストバンドルの注入方式が変わった可能性がある。判定を直すまで App テストはいつ
/// ハングしてもおかしくない状態になる。
///
/// **なお、ハング自体は状態依存で常には再現しない**（復元対象の庫と、それを他インスタンスが
/// 保持しているかの組み合わせに依存する）。「テストが通ったからガードが効いている」とは
/// 言えないため、判定を直接固定するこの形にしている。
///
/// **注意（2026-07-31 実測）**: 判定の保険として `NSClassFromString("XCTestCase")` を
/// 評価したところ、**テストホストがクラッシュした**（swift-testing のみをリンクした
/// テストバンドルから XCTestCase に触れるため）。ここで XCTest 系の API に触れないこと。
///
/// **「ガードが配線されていること」を観察するテストは置いていない。** 一度は
/// `AppState.activeInstances` が空であることを assert する形で書いたが、ガードを外した状態でも
/// 通ってしまい（起動猶予を 2 秒待つ形にしても同じ）、**検出力がゼロであることを実測した**ため
/// 削除した。素通りするテストは、守っているつもりにさせる分だけ無いより悪い。
/// ここで固定できるのは判定機構までで、配線はコードを読んで担保する。
struct AppEnvironmentTests {
    /// テスト実行中は必ず真になること。偽ならガードが死んでいる。
    @Test func detectsThatItIsRunningUnderTests() {
        #expect(AppEnvironment.isRunningUnitTests)
    }

    /// 判定の根拠である環境変数が、このハーネスで実際に設定されていること。
    /// 上のテストと重複して見えるが、こちらが落ちれば原因が「判定の実装」ではなく
    /// 「実行環境の変化」であると切り分けられる。
    @Test func theHarnessSetsTheEnvironmentVariableWeRelyOn() {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
    }
}

/// G31 Task 2 の回帰テスト ―― **テストホストがローカル制御サーバを立てていないこと**。
///
/// **このテストが存在する理由**: ガード（`StackNestApp.swift` の
/// `if !AppEnvironment.isRunningUnitTests { LocalControlController.shared.startIfEnabled() }`）が
/// 外れても、**CI では何も落ちない**。症状が出るのは利用者の手元 ―― `xcodebuild test` が
/// テストホストとして 2 個目の `StackNest.app` を起動し、稼働中の実アプリが握っている
/// ローカル制御ポートに bind できず**再採番して共有 UserDefaults を書き換える**ため、
/// 実アプリは旧ポートで listen したまま defaults だけが新ポートを指し、
/// **CLI と MCP が実アプリ再起動まで接続不能になる**（2026-08-08 実測: defaults 14830 /
/// 実リッスン 46729）。壊れても気づきにくい類なので、ここで縛っておく。
///
/// テストホスト自身の `LocalControlController` を見れば足りる ―― このプロセスで
/// `startIfEnabled()` が呼ばれていなければ `isRunning` は false のままである。
@MainActor
@Suite("ローカル制御サーバはテストホストで起動しない（G31）")
struct LocalControlGuardTests {
    /// **★ Codex レビュー(Medium) を受けて前提を明示した。**
    /// `isRunning == false` を見るだけでは不十分だった ―― `startIfEnabled()` は
    /// `ServerPreferences.localAutomationEnabled()` が false のときも**何もせず返る**ため、
    /// ガードを外してもこのテストは通ってしまう（＝検査になっていない）。
    /// 「ローカルアクセスが有効なのに起動していない」まで言って初めて、
    /// **ガードだけが起動を止めている**ことの証拠になる。
    ///
    /// 既定値は true（`ServerPreferences.localAutomationEnabled` は未設定なら true を返す）なので、
    /// 通常はこの前提が満たされる。満たされない環境ではこのテストは**落ちる** ――
    /// 「検査できていない」ことを黙って緑にするより、落ちて気づく方がよい。
    @Test("ローカルアクセスが有効でも、テストホストでは起動していない")
    func localControlIsNotStartedInTestHost() {
        // 前提 1: テストホストとして走っている（判定そのものが壊れたら気づけるように）。
        #expect(AppEnvironment.isRunningUnitTests)
        // 前提 2: ローカルアクセスは有効 ―― これが false だと startIfEnabled() は
        // ガードの有無に関わらず何もしないので、次の #expect が検査にならない。
        #expect(ServerPreferences.localAutomationEnabled(),
                "ローカルアクセスが無効なため、このテストはガードの有無を区別できない")
        // 本題: それでも起動していない＝ガードが効いている。
        #expect(LocalControlController.shared.isRunning == false)
    }
}
