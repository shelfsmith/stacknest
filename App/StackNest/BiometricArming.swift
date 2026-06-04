// SPDX-License-Identifier: MIT
import Foundation
import AppCore

/// App 層グルー: per-machine の生体認証アーム状態を LibrarySettings（libraryUUID）と
/// BiometricArmStore（UserDefaults）に橋渡しする。
@MainActor
enum BiometricArming {
    static let store = BiometricArmStore()

    /// この Mac での armedHash。libraryUUID が未生成（=未アーム）なら nil。読み取りで UUID は生成しない。
    static func armedHash(for settings: LibrarySettings?) -> String? {
        guard let uuid = settings?.libraryUUID else { return nil }
        return store.armedHash(forLibrary: uuid)
    }

    /// この Mac をアームする（libraryUUID を必要なら生成）。hash は現在の DB lock_password_hash。
    static func arm(_ settings: LibrarySettings?, hash: String) {
        guard let settings else { return }
        let uuid = settings.ensureLibraryUUID()
        store.arm(library: uuid, hash: hash)
    }

    /// この Mac のアームを解除する。libraryUUID が無ければ no-op。
    static func disarm(_ settings: LibrarySettings?) {
        guard let uuid = settings?.libraryUUID else { return }
        store.disarm(library: uuid)
    }
}
