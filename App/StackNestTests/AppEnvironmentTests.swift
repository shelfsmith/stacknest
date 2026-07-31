// SPDX-License-Identifier: MIT
import Testing
import Foundation
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
