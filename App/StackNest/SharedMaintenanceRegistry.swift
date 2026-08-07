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
/// G27b Codex 2nd review Fix3（旧コメントの訂正）: `onProgress`/`onFinished` はかつて no-op
/// だった ―― 当時の理屈は「進捗配信は各 `LibraryServerCore.eventHub` 経由の SSE で行われ、
/// この registry 自身のコールバックは使われない」というものだったが、それは
/// `LocalControlController`（ローカル制御。`/events` はこのアプリ内のどこからも購読されて
/// いない）だけに当てはまる話で、`ServerController`（**ネットワーク**共有サーバ。`/events` は
/// 他機の `RemoteLibraryState` が実際に購読している）にも同じ no-op registry を注入するように
/// なった時点で誤りになっていた。no-op のままだと、リモートクライアントは
/// `complete-metadata`/`compress-covers`/`full-scan` の進捗・完了 SSE と、完了時に流れる
/// `structureChanged`（`compress-covers` 後の表紙リフレッシュの引き金）を一切受け取れない
/// ―― 動いていた機能をこのブランチが壊していた回帰。
///
/// 修正: `onProgress`/`onFinished` は `fanout` へブロードキャストするだけにし、実際の配信は
/// `LibraryServerCore.init` が注入された `fanout` へ購読させる自分の `eventHub` publish
/// クロージャに委ねる（`MaintenanceEventFanout` のドキュメント参照）。`ServerController`／
/// `LocalControlController` はどちらも `LibraryServerCore` 構築時に `maintenanceRegistry:` と
/// `maintenanceEventFanout:` の両方にこのシングルトンを渡す ―― 1 つの registry を複数の
/// core（それぞれ別の eventHub）が共有していても、fanout が「起動中の全 core」へ正しく
/// 配り分ける。
enum SharedMaintenanceRegistry {
    static let fanout = MaintenanceEventFanout()
    static let shared = MaintenanceJobRegistry(
        onProgress: { lib, job, done, total in
            fanout.broadcastProgress(lib, job, done, total)
        },
        onFinished: { lib, job, outcome, count in
            fanout.broadcastFinished(lib, job, outcome, count)
        }
    )
}
