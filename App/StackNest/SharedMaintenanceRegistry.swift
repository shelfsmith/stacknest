// SPDX-License-Identifier: MIT
import Foundation
import LibraryServer

/// Codex 事前レビュー Blocker2 fix: プロセス内で「ライブラリごとに同時 1 本のメンテナンス
/// ジョブ（整合性フルスキャン等）」という不変条件を、共有ネットワークサーバ（`ServerController`）と
/// ローカル制御（`LocalControlController` = CLI/MCP、および GUI の `IntegrityWindow`）の**両方**で
/// 保証するための、プロセス内で唯一の `MaintenanceJobRegistry` インスタンス。
///
/// 従来は `LocalControlController` がこのインスタンスを所有し、`ServerController` は
/// `LibraryServerCore` 構築時に `maintenanceRegistry:` を渡していなかった（省略時は
/// `LibraryServerCore` が自前で 1 個作る）。結果として、共有サーバ経由のフルスキャンと
/// ローカル/GUI 経由のフルスキャンが**別の registry** で「busy」を判定してしまい、同じ
/// ライブラリに対して 2 本のスキャンが並走できた ―― 一方が確定させた `damaged` を、
/// 他方の遅れて届く `ok` が上書きしてしまう実害（`prev_status=damaged, status=ok` で
/// 破損が damaged 件数・degraded 件数・一覧のいずれからも消える）に直結する。
///
/// 置き場所を `LocalControlController`（CLI/MCP 制御）にしたままだと、`ServerController`
/// （ネットワーク共有）が「自分の生死に無関係な他コントローラのプロパティ」に依存する形になり
/// 所有関係が歪む（逆に `ServerController` 側に置いても同じ問題が反転するだけ）。
/// どちらの子でもない中立の置き場所へ hoist し、両コントローラがここを参照する。
///
/// `onProgress`/`onFinished` は no-op ―― 進捗配信は各 `LibraryServerCore.eventHub` 経由の SSE で
/// 行われ、この registry 自身のコールバックは使われない（`LibraryServerCore.init` のコメント参照。
/// ローカル制御の `/events` はこのアプリ内のどこからも購読されていない）。
enum SharedMaintenanceRegistry {
    static let shared = MaintenanceJobRegistry(
        onProgress: { _, _, _, _ in },
        onFinished: { _, _, _, _ in }
    )
}
