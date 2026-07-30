// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore

extension LibrarySettingsSheet {
    @ViewBuilder
    func lockSection() -> some View {
        let isLocked = settings.lockPasswordHash != nil

        GroupBox("ロック設定") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("このライブラリにパスワードロックを設定する", isOn: Binding(
                    get: { isLocked || lockToggleOn },
                    set: { newVal in
                        if isLocked && !newVal {
                            // ON → OFF 切替: confirm sheet 表示、即クリアしない
                            confirmingDisableLock = true
                        } else if !isLocked && newVal {
                            // OFF → ON 切替: 新規 password 入力フィールド表示
                            lockToggleOn = true
                        } else {
                            // 同じ状態に戻った or ロック未設定で OFF: 何もしない
                            lockToggleOn = newVal
                        }
                    }
                ))

                if lockToggleOn || isLocked {
                    SecureField("パスワード", text: $passwordInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    SecureField("パスワード (確認)", text: $passwordConfirm)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)

                    if !passwordInput.isEmpty && passwordInput != passwordConfirm {
                        Text("確認パスワードが一致しません")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Toggle("生体認証 / Apple Watch でも解錠を許可", isOn: $useBiometricInput)

                    if useBiometricInput {
                        let (canEval, kind) = LibraryLock.canEvaluateBiometricOrWatch()
                        Text(biometricStatusLabel(canEval: canEval, kind: kind))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }
        .sheet(isPresented: $confirmingDisableLock) {
            VStack(alignment: .leading, spacing: 12) {
                Text("ロックを解除するには現在のパスワードを入力してください")
                    .font(.body)

                SecureField("現在のパスワード", text: $disableLockPassword)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { confirmDisableLock() }

                if let err = disableLockError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("キャンセル") {
                        disableLockPassword = ""
                        disableLockError = nil
                        confirmingDisableLock = false
                    }
                    Spacer()
                    Button("ロック解除") {
                        confirmDisableLock()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(disableLockPassword.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
    }

    func biometricStatusLabel(canEval: Bool, kind: BiometryKind) -> String {
        guard canEval else {
            return "この Mac では生体認証 / Apple Watch が利用できません。パスワードのみで解錠されます。"
        }
        switch kind {
        case .touchID: return "Touch ID / Apple Watch で解錠できます"
        case .appleWatch: return "Apple Watch で解錠できます"
        default: return "生体認証で解錠できます"
        }
    }

    func confirmDisableLock() {
        guard let hash = settings.lockPasswordHash,
              let salt = settings.lockPasswordSalt else {
            // hash/salt が無いのに confirm sheet が出る状況は想定外 — fallback で sheet 閉じる
            confirmingDisableLock = false
            return
        }
        if LibraryLock.verify(password: disableLockPassword, saltHex: salt, against: hash) {
            // 正しい password: クリア実行
            // G25c: salt/hash は組でまとめて消す。
            try? settings.clearLock()
            settings.useBiometric = false
            BiometricArming.disarm(settings)
            if let url = bundleURL { LibraryLock.purgeLegacyKeychainItem(bundleURL: url) }
            // UI state クリア
            passwordInput = ""
            passwordConfirm = ""
            lockToggleOn = false
            disableLockPassword = ""
            disableLockError = nil
            confirmingDisableLock = false
        } else {
            // 間違い: 入力欄クリア + error 表示
            disableLockPassword = ""
            disableLockError = "パスワードが違います"
        }
    }
}
