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

/// 開いているリモートライブラリ state のレジストリ（AppState.activeInstances 相当）。
/// ⌘⇧O で既に開いているウィンドウの本を直接開くために使う。weak 参照。
@MainActor
final class RemoteLibraryRegistry {
    static let shared = RemoteLibraryRegistry()
    private let table = NSHashTable<RemoteLibraryState>.weakObjects()
    func add(_ s: RemoteLibraryState) { table.add(s) }
    /// #7: ウィンドウ閉鎖時に明示的に外す。weak table は dealloc 時に自動で外れるが、
    /// SwiftUI の @State/Task 保持で state が閉鎖後も生き残ると、resume の already-open 枝が
    /// 「開いている」と誤認してしまう。閉鎖を検知したら即座に外し、閉じた庫は cold path
    /// （NSAlert 解錠→新ウィンドウで続きを開く）へ落とす。
    func remove(_ s: RemoteLibraryState) { table.remove(s) }
    var allObjects: [RemoteLibraryState] { table.allObjects }
}
