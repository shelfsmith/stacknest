import Foundation

/// アプリの実行環境の判定。
enum AppEnvironment {
    /// **App ユニットテスト（XCTest ホスト）として起動されたか。**
    ///
    /// App ターゲットのユニットテストは、`StackNest.app` 本体をテストホストとして起動し、
    /// テストバンドルをそのプロセスに注入する形で走る。したがって通常起動と同じ経路で
    /// 起動時のライブラリ復元が動き、そこでモーダル（`NSAlert.runModal` /
    /// `NSApplication.runModalForWindow:`）が提示されると、**閉じる者がいないため
    /// テストが永久に停止する**。
    ///
    /// 2026-07-31 に実測: 別インスタンスが同じ庫を保持している状態でテストを回したところ、
    /// `LibraryWindowContainer.confirmForceOpen`（「他所で開かれています／強制的に開くか」）が
    /// モーダルを出して 28 分停止した。**発生は状態依存**（復元対象と保持状態の組み合わせ）で、
    /// 常に起きるわけではない分だけ質が悪い。
    ///
    /// 真のときは起動時のウィンドウ提示を一切行わず、モーダルは安全側の既定で即答する。
    ///
    /// **判定は `XCTestConfigurationFilePath` 一本に絞ってある。** 当初は
    /// `NSClassFromString("XCTestCase") != nil` を保険として併用したが、**これを評価すると
    /// テストホストがクラッシュした**（2026-07-31 実測。swift-testing のみをリンクした
    /// テストバンドルで XCTestCase に触れるため）。評価するとクラッシュするものは保険にならない。
    /// 環境変数が設定されなくなった場合は `AppEnvironmentTests` が落ちて気づける。
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
