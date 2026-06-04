// SPDX-License-Identifier: MIT
import Foundation
import CryptoKit
import Security
import LocalAuthentication
import OSLog

public enum LockState: Equatable, Sendable {
    case noPassword
    case unlocked
    case locked
}

public enum LibraryLockError: Error, Equatable {
    case keychainError(OSStatus)
    case dataEncodingFailed
    case biometricUnavailable
    case biometricFailed
}

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
        return computed == expectedHash
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

    // MARK: - Keychain

    /// Saves a password to the Keychain without ACL (no entitlement required).
    ///
    /// Security design: The Keychain item is stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
    /// but WITHOUT a `SecAccessControl` ACL that would require the Keychain Sharing entitlement
    /// (errSecMissingEntitlement -34018). Biometric gating is performed at the app layer via
    /// `LAContext.evaluatePolicy` in `LibraryUnlockSheet`, which does not require additional
    /// entitlements. The `biometryProtected` parameter is retained for API compatibility and
    /// logging purposes only.
    public static func saveKeychainPassword(
        _ password: String,
        service: String,
        account: String,
        biometryProtected: Bool  // retained for API compat; biometric gate is app-layer (LAContext)
    ) throws {
        guard let data = password.data(using: .utf8) else {
            throw LibraryLockError.dataEncodingFailed
        }
        try? deleteKeychainPassword(service: service, account: account)

        // ACL (SecAccessControlCreateWithFlags) requires Keychain Sharing entitlement
        // which is not available in unsigned/development builds (errSecMissingEntitlement -34018).
        // Store without ACL; biometric authentication is handled by LAContext in LibraryUnlockSheet.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("SecItemAdd FAILED status=\(status) service=\(service) account=\(account, privacy: .public)")
            throw LibraryLockError.keychainError(status)
        }
        logger.info("SecItemAdd OK service=\(service) account=\(account, privacy: .public) biometry=\(biometryProtected) (ACL: none — app-side gated)")
    }

    public static func loadKeychainPassword(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            logger.warning("Keychain item NOT FOUND service=\(service) account=\(account, privacy: .public)")
            return nil
        }
        if status != errSecSuccess {
            logger.error("SecItemCopyMatching FAILED status=\(status) service=\(service) account=\(account, privacy: .public)")
            throw LibraryLockError.keychainError(status)
        }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            logger.error("Keychain data cast/decode FAILED service=\(service) account=\(account, privacy: .public)")
            return nil
        }
        logger.info("SecItemCopyMatching OK service=\(service) account=\(account, privacy: .public)")
        return string
    }

    public static func deleteKeychainPassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            logger.error("SecItemDelete FAILED status=\(status) service=\(service) account=\(account, privacy: .public)")
            throw LibraryLockError.keychainError(status)
        }
        logger.info("SecItemDelete OK (or notFound) status=\(status) service=\(service) account=\(account, privacy: .public)")
    }

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
