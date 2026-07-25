// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
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

    public static func computeHash(password: String, saltHex: String) -> String {
        let saltBytes = bytes(fromHex: saltHex) ?? []
        var combined = Data(saltBytes)
        combined.append(Data(password.utf8))
        let digest = SHA256.hash(data: combined)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(password: String, saltHex: String, against expectedHash: String) -> Bool {
        let computed = computeHash(password: password, saltHex: saltHex)
        return constantTimeEquals(computed, expectedHash)
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
