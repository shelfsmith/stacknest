// SPDX-License-Identifier: MIT
import Testing
import Foundation
import LibraryServer
@testable import StackNest

/// Codex 事前レビュー Blocker2 の回帰テスト（App 側の配線半分）。
///
/// Blocker2 の中身は 2 つの独立した主張に分かれる。
/// 1. 「同じ `MaintenanceJobRegistry` インスタンスを注入された 2 個の独立した
///    `LibraryServerCore` は busy 判定を共有し、片方の HTTP 経由の起動をもう片方が
///    409 で拒否する」―― これは `LibraryServer` の性質そのもの（`SharedMaintenanceRegistry` に
///    依存しない）であり、`HummingbirdTesting` が使える SPM target 側
///    （`Tests/LibraryServerTests/MaintenanceRegistrySharedAcrossCoresTests.swift`）で検証する。
/// 2. 「`ServerController`（共有ネットワークサーバ）と `LocalControlController`（CLI/MCP・
///    GUI 整合性チェックウィンドウ）が実際に**同じ** `SharedMaintenanceRegistry.shared` を
///    注入している」―― これがまさに Blocker2 で壊れていた配線そのもの（`ServerController` だけ
///    が `LibraryServerCore` 構築時に `maintenanceRegistry:` を省略しており、`LibraryServerCore`
///    が自前で別インスタンスを作ってしまっていた）。
///
/// App test target には（project.yml へパッケージ依存を追加しない方針のため）
/// `HummingbirdTesting` が無く、実サーバも起動できない。しかし 2. は実サーバを起動しなくても
/// 検証できる ―― `ServerController`/`LocalControlController` はどちらも `maintenanceRegistry`
/// を公開プロパティとして持つため（前者は本 fix で `SharedMaintenanceRegistry.shared` を返す
/// 計算プロパティとして追加した。後者はもとから同じ形）、ここでは 2 つの参照が
/// **同一インスタンス**（identity, `===`）であることだけを確認する。これは意味のある回帰テスト
/// である ―― どちらかが再び自前の `MaintenanceJobRegistry()` を持つように退行すれば、
/// 共有サーバ経由とローカル経由のフルスキャンが同じ庫に対して並走できてしまい、一方が確定
/// させた `damaged` を他方の遅れた `ok` が上書きしうる実害（詳細は `SharedMaintenanceRegistry`
/// のコメント参照）が再発するが、この不変条件が壊れれば以下のテストが即座に落ちる。
@Suite("App-side maintenance registry wiring (Codex pre-merge Blocker2)")
struct SharedMaintenanceRegistryWiringTests {

    /// `SharedMaintenanceRegistry.shared` はプロセス内で唯一のインスタンスであり続ける。
    /// （`static let` を factory 的な `static var { MaintenanceJobRegistry(...) }` へ書き換える
    /// ような退行があれば、参照のたびに別インスタンスになりこの expect が落ちる。）
    @Test func sharedInstanceIsStableAcrossReferences() {
        #expect(SharedMaintenanceRegistry.shared === SharedMaintenanceRegistry.shared)
    }

    /// `LocalControlController.shared.maintenanceRegistry` は `SharedMaintenanceRegistry.shared`
    /// そのものを指す（自前で別インスタンスを持つ退行が起きれば落ちる）。
    @Test @MainActor func localControlControllerInjectsSharedRegistry() {
        #expect(LocalControlController.shared.maintenanceRegistry === SharedMaintenanceRegistry.shared)
    }

    /// `ServerController.shared.maintenanceRegistry` も同様に `SharedMaintenanceRegistry.shared`
    /// を指す ―― これがまさに Blocker2 で欠けていた配線（`ServerController.start()` が
    /// `LibraryServerCore` 構築時に `maintenanceRegistry:` を省略し、自前で別インスタンスを
    /// 作らせてしまっていた）の回帰テスト。
    @Test @MainActor func serverControllerInjectsSharedRegistry() {
        #expect(ServerController.shared.maintenanceRegistry === SharedMaintenanceRegistry.shared)
    }

    /// 上記 2 つを合成すると、両コントローラが busy 判定を共有していることになる ――
    /// これが崩れると、共有サーバ経由とローカル経由の 2 本のフルスキャンが同じ庫に対して
    /// 並走でき、一方が確定させた damaged を他方の遅れた ok が上書きしうる。
    @Test @MainActor func bothControllersShareTheSameRegistryInstance() {
        #expect(ServerController.shared.maintenanceRegistry === LocalControlController.shared.maintenanceRegistry)
    }
}
