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

/// G25c: #8 の遅延ハッシュ移行（旧 SHA-256 / 旧 iteration → 現行 PBKDF2）を DB へ書き戻してよいかの純粋判定。
///
/// 移行は**書き込み**なので compare-and-set が必要。解錠シートは構築時のハッシュ（`verifiedAgainst`）を
/// 保持し続けるため、検証が通った時点で現在値が別のものへ差し替えられている可能性がある
/// （外部経路＝CLI/MCP/共有サーバの `reloadLockSettings()`）。無条件に書き戻すと、
/// **外部が設定した新パスワードのハッシュを旧パスワード由来のハッシュで巻き戻す**＝ロックのダウングレードになる。
///
/// - Parameters:
///   - verifiedAgainst: この試行で実際に照合したハッシュ。
///   - current: 書き戻し直前の DB 上のハッシュ（施錠解除済みなら nil）。
/// - Returns: `current` が `verifiedAgainst` と同一のときだけ true。
public func shouldPersistHashUpgrade(verifiedAgainst: String, current: String?) -> Bool {
    guard let current, !current.isEmpty else { return false }
    return current == verifiedAgainst
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
