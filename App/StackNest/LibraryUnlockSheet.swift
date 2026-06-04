// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore
import OSLog

struct LibraryUnlockSheet: View {
    let bundleURL: URL
    let bundleName: String
    let salt: String
    let hash: String
    let useBiometric: Bool
    let onUnlock: () -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var failureCount = 0
    @State private var biometricInfo: (canEvaluate: Bool, kind: BiometryKind) = (false, .none)
    @State private var isAttemptingBiometric = false
    /// Task 6: per-machine biometric setup prompt
    @State private var showBiometricSetupPrompt = false
    @State private var pendingPlainPassword: String?

    private let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "LibraryUnlockSheet")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("「\(bundleName)」 を開く")
                .font(.title2.bold())

            Text("パスワードを入力してください")
                .foregroundStyle(.secondary)

            SecureField("", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { tryPassword() }

            if failureCount > 0 {
                Text("パスワードが違います (\(failureCount) 回失敗)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if useBiometric && biometricInfo.canEvaluate {
                HStack {
                    Spacer()
                    Button(action: tryBiometric) {
                        let label: String = {
                            switch biometricInfo.kind {
                            case .touchID: return "Touch ID で解錠"
                            case .appleWatch: return "Apple Watch で解錠"
                            default: return "生体認証で解錠"
                            }
                        }()
                        Label(label, systemImage: biometricInfo.kind == .appleWatch ? "applewatch" : "touchid")
                    }
                    .disabled(isAttemptingBiometric)
                    Spacer()
                }
            }

            HStack {
                Spacer()
                Button("キャンセル") { onCancel() }
                    .keyboardShortcut(.cancelAction)  // ESC で発火
                Button("開く") { tryPassword() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            biometricInfo = LibraryLock.canEvaluateBiometricOrWatch()
            if useBiometric && biometricInfo.canEvaluate {
                tryBiometric()
            }
        }
        // Task 6: per-machine biometric setup alert
        .alert("このマシンで生体認証を設定", isPresented: $showBiometricSetupPrompt) {
            Button("設定する") { setupBiometricOnThisMachine() }
            Button("あとで") {
                pendingPlainPassword = nil
                onUnlock()
            }
        } message: {
            Text("このライブラリは他のマシンで生体認証が有効ですが、このマシンでは未設定です。\n" +
                 "今入力したパスワードをこのマシンの Keychain に保存し、次回から生体認証で解錠できるようにしますか?")
        }
    }

    private func tryPassword() {
        guard !password.isEmpty else { return }
        if LibraryLock.verify(password: password, saltHex: salt, against: hash) {
            handlePasswordUnlockSuccess(plain: password)
        } else {
            failureCount += 1
            password = ""
        }
    }

    /// Task 6: パスワード解錠成功後の処理。
    /// useBiometric=true かつ現マシンの Keychain に item がなければ setup prompt を表示。
    /// それ以外は従来動作 (useBiometric なら即 Keychain 保存 → onUnlock)。
    private func handlePasswordUnlockSuccess(plain: String) {
        if useBiometric {
            do {
                let existing = try LibraryLock.loadKeychainPassword(
                    service: LibraryLock.defaultService,
                    account: bundleURL.absoluteString
                )
                if existing == nil {
                    // このマシンには未登録 → prompt を表示
                    pendingPlainPassword = plain
                    showBiometricSetupPrompt = true
                    return
                } else {
                    // 既に Keychain item あり → 上書き不要、そのまま解錠
                    onUnlock()
                    return
                }
            } catch {
                // Keychain エラーは prompt なしで通常解錠
                logger.error("handlePasswordUnlockSuccess: Keychain check error: \(error.localizedDescription)")
            }
        }
        onUnlock()
    }

    /// Task 6: 現マシンの Keychain に plaintext password を保存してから onUnlock。
    private func setupBiometricOnThisMachine() {
        guard let plain = pendingPlainPassword else { onUnlock(); return }
        do {
            try LibraryLock.saveKeychainPassword(
                plain,
                service: LibraryLock.defaultService,
                account: bundleURL.absoluteString,
                biometryProtected: true
            )
            logger.info("setupBiometricOnThisMachine: Keychain saved for bundleURL=\(bundleURL.absoluteString, privacy: .public)")
        } catch {
            logger.error("setupBiometricOnThisMachine: Keychain save failed: \(error.localizedDescription)")
        }
        pendingPlainPassword = nil
        onUnlock()
    }

    private func tryBiometric() {
        logger.info("tryBiometric: start bundleURL=\(bundleURL.absoluteString, privacy: .public)")
        isAttemptingBiometric = true
        LibraryLock.evaluateBiometric(reason: "「\(bundleName)」 のロックを解除") { success, evalError in
            isAttemptingBiometric = false
            logger.info("evaluateBiometric callback: success=\(success) error=\(evalError?.localizedDescription ?? "nil")")
            guard success else {
                logger.warning("tryBiometric: biometric evaluation failed or cancelled, falling back to password")
                return
            }
            do {
                let plain = try LibraryLock.loadKeychainPassword(
                    service: LibraryLock.defaultService,
                    account: bundleURL.absoluteString
                )
                if let p = plain {
                    if LibraryLock.verify(password: p, saltHex: salt, against: hash) {
                        logger.info("tryBiometric: Keychain plain verified, calling onUnlock")
                        onUnlock()
                    } else {
                        logger.warning("tryBiometric: Keychain plain did NOT verify against stored hash (stale Keychain?)")
                    }
                } else {
                    logger.warning("tryBiometric: Keychain plain was nil — item missing or not found")
                }
            } catch {
                logger.error("tryBiometric: Keychain load error: \(error.localizedDescription)")
                // fall back to password input
            }
        }
    }
}
