// SPDX-License-Identifier: MIT
import Foundation

/// 開いている AppState を弱参照で追跡する @Observable なレジストリ。
///
/// 旧実装は `NSHashTable<AppState>.weakObjects()` を直接 static で保持していたが、
/// NSHashTable は @Observable ではないため、ライブラリ開閉でメンバーが増減しても
/// SwiftUI（SharingSettingsView の「配信ライブラリ」リスト等）が再描画されず、
/// 配信対象が更新されなかった（4.1b smoke F2）。
///
/// このレジストリは内部に NSHashTable を隠蔽し、メンバー増減のたびに `version` を
/// インクリメントする。`allObjects` の読み取り時に `version` も touch することで、
/// @Observable の dependency tracking に version を載せ、add/remove → SwiftUI 再描画を
/// 成立させる。
@Observable
@MainActor
final class AppStateRegistry {
    /// 内部の弱参照テーブル。外部には公開しない。
    @ObservationIgnored
    private let table = NSHashTable<AppState>.weakObjects()

    /// メンバー増減のたびに bump する版数。`allObjects` 経由で read され、
    /// add/remove → @Observable 再描画のトリガになる。
    private var version = 0

    /// 現在登録されている AppState の配列。
    /// version を read することで、メンバー増減を観察する view の dependency に載せる。
    var allObjects: [AppState] {
        _ = version  // dependency tracking: 増減で再描画させる
        return table.allObjects
    }

    func add(_ state: AppState) {
        table.add(state)
        version &+= 1
    }

    func remove(_ state: AppState) {
        table.remove(state)
        version &+= 1
    }
}
