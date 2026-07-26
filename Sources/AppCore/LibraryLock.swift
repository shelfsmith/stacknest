// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import CommonCrypto
import Security
import LocalAuthentication
import OSLog

public enum BiometryKind: Equatable, Sendable {
    case none
    case touchID
    case appleWatch
    case unknownBiometry

    static func from(context: LAContext, canEval: Bool) -> BiometryKind {
        guard canEval else { return .none }
        switch context.biometryType {
        case .touchID: return .touchID
        case .opticID, .faceID: return .unknownBiometry
        case .none:
            // canEval=true && biometryType=.none => Apple Watch unlock candidate
            return .appleWatch
        @unknown default:
            return .unknownBiometry
        }
    }
}

public enum LibraryLock {
    private static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "LibraryLock")
    public static let defaultService = "app.shelfsmith.stacknest.lock"

    // MARK: - Salt + Hash

    public static func generateSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(result == errSecSuccess)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// G23 (#8): PBKDF2-HMAC-SHA256 の反復回数（OWASP 推奨値）。
    public static let pbkdf2Iterations = 210_000

    /// 保存値から読み取る反復回数の上限。DB 破損や改竄で極端な値が入っていた場合に、
    /// `UInt32` 変換の trap や解錠時の過大な CPU 消費を防ぐ（現行値の 10 倍まで許容）。
    public static let maxAcceptedIterations = 2_100_000

    private static let pbkdf2Prefix = "pbkdf2$"

    /// 検証結果。`.ok(upgradedHash:)` の値が非 nil なら、呼び出し側はそれを保存して
    /// 旧形式から移行する。**解錠成功時にしか平文パスワードは手に入らない**ため、
    /// 移行を行えるのはこの瞬間だけ。
    public enum VerificationOutcome: Equatable, Sendable {
        case failed
        case ok(upgradedHash: String?)
    }

    /// 現行形式のハッシュ（`pbkdf2$<iterations>$<hex>`）を返す。
    public static func computeHash(password: String, saltHex: String) -> String {
        pbkdf2Hash(password: password, saltHex: saltHex, iterations: pbkdf2Iterations)
    }

    /// 指定反復回数の PBKDF2 ハッシュを形式付きで返す（テストと移行判定から使う）。
    public static func pbkdf2Hash(password: String, saltHex: String, iterations: Int) -> String {
        "\(pbkdf2Prefix)\(iterations)$\(pbkdf2Hex(password: password, saltHex: saltHex, iterations: iterations))"
    }

    /// 旧形式（ソルト付き SHA-256 の生 hex）。**新規生成には使わない**。
    /// 既存ライブラリの検証と移行判定のためだけに残す。
    public static func legacySHA256Hash(password: String, saltHex: String) -> String {
        let saltBytes = bytes(fromHex: saltHex) ?? []
        var combined = Data(saltBytes)
        combined.append(Data(password.utf8))
        return SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined()
    }

    /// 検証し、保存値が旧形式（または古い反復回数）だった場合は移行後の値を併せて返す。
    public static func verifyAndUpgrade(password: String, saltHex: String,
                                        against expectedHash: String) -> VerificationOutcome {
        if expectedHash.hasPrefix(pbkdf2Prefix) {
            // "pbkdf2$<iterations>$<hex>"
            let parts = expectedHash.split(separator: "$", maxSplits: 2, omittingEmptySubsequences: false)
            // G23 Codex その他: 保存値が壊れている場合の防御。反復回数に上限を設けないと、
            // 巨大な値で `UInt32` 変換が trap したり、解錠のたびに極端な CPU を消費させられる。
            // ダイジェスト長（SHA-256 = 64 桁 hex）も形式として検証する。
            guard parts.count == 3,
                  let iterations = Int(parts[1]),
                  (1...maxAcceptedIterations).contains(iterations),
                  parts[2].count == 64,
                  parts[2].allSatisfy({ $0.isHexDigit })
            else { return .failed }
            let computed = pbkdf2Hex(password: password, saltHex: saltHex, iterations: iterations)
            guard constantTimeEquals(computed, String(parts[2])) else { return .failed }
            // 反復回数が現行値より古ければ作り直す。
            return .ok(upgradedHash: iterations == pbkdf2Iterations
                       ? nil
                       : computeHash(password: password, saltHex: saltHex))
        }
        // 旧形式: SHA-256 で検証し、成功したらこの場で PBKDF2 へ移行する。
        guard !expectedHash.isEmpty,
              constantTimeEquals(legacySHA256Hash(password: password, saltHex: saltHex), expectedHash) else {
            return .failed
        }
        return .ok(upgradedHash: computeHash(password: password, saltHex: saltHex))
    }

    public static func verify(password: String, saltHex: String, against expectedHash: String) -> Bool {
        verifyAndUpgrade(password: password, saltHex: saltHex, against: expectedHash) != .failed
    }

    /// PBKDF2-HMAC-SHA256（32 バイト）を hex で返す。
    private static func pbkdf2Hex(password: String, saltHex: String, iterations: Int) -> String {
        let saltBytes = bytes(fromHex: saltHex) ?? []
        var derived = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        let status = pw.withUnsafeBufferPointer { pwBuf in
            saltBytes.withUnsafeBufferPointer { saltBuf in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBuf.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    pw.count,
                    saltBuf.baseAddress, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                    &derived, derived.count)
            }
        }
        precondition(status == kCCSuccess, "CCKeyDerivationPBKDF failed: \(status)")
        return derived.map { String(format: "%02x", $0) }.joined()
    }

    /// G23: 長さが異なっても全バイト走査する定数時間比較（タイミング攻撃対策）。
    /// LibraryServer 側の `constantTimeEquals`（AuthMiddleware.swift）と同じ実装だが、
    /// あちらは LibraryServer モジュール内のファイルスコープ関数で AppCore からは見えないため
    /// ここにも持つ。ハッシュ比較の早期 return をなくすのが目的。
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8), bBytes = Array(b.utf8)
        var diff = aBytes.count ^ bBytes.count
        for i in 0..<max(aBytes.count, bBytes.count) {
            let x = i < aBytes.count ? aBytes[i] : 0
            let y = i < bBytes.count ? bBytes[i] : 0
            diff |= Int(x ^ y)
        }
        return diff == 0
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            let byteStr = hex[index..<nextIndex]
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            result.append(byte)
            index = nextIndex
        }
        return result
    }

    // MARK: - Legacy Keychain Purge

    /// Best-effort cleanup of the pre-2.6g plaintext Keychain item for a library.
    /// 2.6g moved biometric arming off the Keychain; this removes the legacy plaintext
    /// item (service=`defaultService`, account=bundleURL) if present. Never throws:
    /// failures (including item-not-found) are logged and ignored — the feature does not
    /// depend on the Keychain, so cleanup is purely hygienic.
    public static func purgeLegacyKeychainItem(bundleURL: URL) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: defaultService,
            kSecAttrAccount as String: bundleURL.absoluteString
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess {
            logger.info("purgeLegacyKeychainItem: removed legacy item for \(bundleURL.lastPathComponent, privacy: .public)")
        } else if status != errSecItemNotFound {
            logger.warning("purgeLegacyKeychainItem: SecItemDelete status=\(status) item=\(bundleURL.lastPathComponent, privacy: .public) (ignored)")
        }
    }

    // MARK: - LAContext

    // macOS 15+: renamed from deviceOwnerAuthenticationWithBiometricsOrWatch
    private static var biometricOrCompanionPolicy: LAPolicy {
        .deviceOwnerAuthenticationWithBiometricsOrCompanion
    }

    public static func canEvaluateBiometricOrWatch() -> (canEvaluate: Bool, kind: BiometryKind) {
        let context = LAContext()
        var error: NSError?
        let canEval = context.canEvaluatePolicy(biometricOrCompanionPolicy, error: &error)
        let kind = BiometryKind.from(context: context, canEval: canEval)
        return (canEval, kind)
    }

    public static func evaluateBiometric(
        reason: String,
        completion: @escaping @MainActor (Bool, Error?) -> Void
    ) {
        let context = LAContext()
        let policy = biometricOrCompanionPolicy
        var error: NSError?
        let canEval = context.canEvaluatePolicy(policy, error: &error)
        logger.info("evaluateBiometric: canEvaluatePolicy=\(canEval) error=\(error?.localizedDescription ?? "nil")")
        guard canEval else {
            logger.error("evaluateBiometric: canEvaluatePolicy=false, aborting. error=\(error?.localizedDescription ?? "nil")")
            Task { @MainActor in completion(false, error) }
            return
        }
        context.evaluatePolicy(policy, localizedReason: reason) { success, evalError in
            if success {
                Self.logger.info("LAContext.evaluatePolicy SUCCESS")
            } else {
                Self.logger.error("LAContext.evaluatePolicy FAILED: \(evalError?.localizedDescription ?? "nil")")
            }
            Task { @MainActor in completion(success, evalError) }
        }
    }
}
