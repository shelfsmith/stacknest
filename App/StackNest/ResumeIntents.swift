// SPDX-License-Identifier: MIT
import Foundation
import AppCore

/// リモート再オープンの保留意図（ウィンドウ生成時に1回消費）。
struct PendingRemoteOpen: Equatable {
    let serverID: UUID
    let libraryUUID: String
    let bookID: Int
    let libraryToken: String?   // 解錠済みなら設定（庫内パス画面スキップ）
    let forceResume: Bool       // 続き確認なしで最終ページ直行
}

@MainActor
final class RemoteResumeIntent {
    static let shared = RemoteResumeIntent()
    var pending: PendingRemoteOpen?
    /// セッション unlock トークンキャッシュ（"serverID/libraryUUID" → token・メモリのみ）。
    var unlockTokens: [String: String] = [:]
    static func key(_ serverID: UUID, _ libraryUUID: String) -> String { "\(serverID.uuidString)/\(libraryUUID)" }

    /// 自分(serverID,libraryUUID)宛ての pending を取り出して消す。
    func take(serverID: UUID, libraryUUID: String) -> PendingRemoteOpen? {
        guard let p = pending, p.serverID == serverID, p.libraryUUID == libraryUUID else { return nil }
        pending = nil
        return p
    }
}

@MainActor
final class LocalResumeIntent {
    static let shared = LocalResumeIntent()
    /// bundlePath → 開く bookID（ライブラリ読み込み完了時に消費）。
    var pending: (bundlePath: String, bookID: Int)?
}

@MainActor
final class OfflineResumeIntent {
    static let shared = OfflineResumeIntent()
    var pendingBookID: Int?
}
