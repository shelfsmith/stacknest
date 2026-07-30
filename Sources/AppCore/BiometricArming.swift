// SPDX-License-Identifier: MIT
import Foundation

/// 生体認証成功後に「パスワード入力無しで解錠してよいか」の判定結果。
public enum BiometricUnlockDecision: Equatable, Sendable {
    /// この Mac はアーム済みで、アーム時ハッシュが現在の DB ハッシュと一致する。
    case unlock
    /// 未アーム、または別 Mac でパスワードが変更された。パスワード入力が必要。
    case requirePassword
}

/// 生体認証成功後の純粋判定。
/// armedHash（この Mac のローカル値）が現在の DB ハッシュ（currentHash）と一致するときだけ解錠。
public func decideBiometricUnlock(armedHash: String?, currentHash: String) -> BiometricUnlockDecision {
    guard let armed = armedHash, !armed.isEmpty, armed == currentHash else {
        return .requirePassword
    }
    return .unlock
}

/// per-machine の armedHash 保管庫。バンドルには入らず、その Mac の `UserDefaults` に保存する。
/// キーは `keyPrefix + libraryUUID`。保存値はロックパスワードのハッシュ（DB と同値・平文ではない）。
///
/// `UserDefaults` は Apple ドキュメントでスレッドセーフと保証されているため
/// `@unchecked Sendable` を使用する（Swift 6 strict concurrency 対応）。
public struct BiometricArmStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "lock.armedHash.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func key(_ libraryKey: String) -> String { keyPrefix + libraryKey }

    public func armedHash(forLibrary libraryKey: String) -> String? {
        defaults.string(forKey: key(libraryKey))
    }

    public func arm(library libraryKey: String, hash: String) {
        defaults.set(hash, forKey: key(libraryKey))
    }

    public func disarm(library libraryKey: String) {
        defaults.removeObject(forKey: key(libraryKey))
    }
}
