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
    /// この Mac の armedHash を返す（未アームなら nil）。
    let armedHash: () -> String?
    /// この Mac をアームする（パスワード入力成功時に呼ぶ）。
    let armThisMachine: () -> Void
    let onUnlock: () -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var failureCount = 0
    @State private var biometricInfo: (canEvaluate: Bool, kind: BiometryKind) = (false, .none)
    @State private var isAttemptingBiometric = false
    /// 生体認証は成功したが、この Mac が未アーム/パスワード変更でパスワードが必要なときに表示するヒント。
    @State private var showPasswordHint = false

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

            if showPasswordHint {
                Text("この Mac で生体認証を有効にするため、パスワードの入力が必要です")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                            case .touchID: return "Touch ID / Apple Watch で解錠"
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
    }

    private func tryPassword() {
        guard !password.isEmpty else { return }
        if LibraryLock.verify(password: password, saltHex: salt, against: hash) {
            // パスワード証明成功: 生体認証有効ならこの Mac を自動アーム（平文は保存されない）。
            if useBiometric {
                armThisMachine()
            }
            onUnlock()
        } else {
            failureCount += 1
            password = ""
        }
    }

    private func tryBiometric() {
        logger.info("tryBiometric: start bundleURL=\(bundleURL.absoluteString, privacy: .public)")
        isAttemptingBiometric = true
        LibraryLock.evaluateBiometric(reason: "「\(bundleName)」 のロックを解除") { success, evalError in
            isAttemptingBiometric = false
            logger.info("evaluateBiometric callback: success=\(success) error=\(evalError?.localizedDescription ?? "nil")")
            guard success else {
                logger.warning("tryBiometric: biometric evaluation failed or cancelled, falling back to password")
                return  // showPasswordHint は維持 — 一度 requirePassword と判定されたら残す
            }
            switch decideBiometricUnlock(armedHash: armedHash(), currentHash: hash) {
            case .unlock:
                logger.info("tryBiometric: armed hash matches current — unlocking")
                onUnlock()
            case .requirePassword:
                logger.info("tryBiometric: not armed on this machine (or password changed) — require password")
                showPasswordHint = true
            }
        }
    }
}
