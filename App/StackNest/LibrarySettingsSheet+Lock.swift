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
        .sheet(isPresented: $confirmingChangeLock) {
            // G27a Task6: パスワード変更の確認シート。confirmingDisableLock と同じ見た目・流儀
            // （SecureField 1 個＋エラー文言＋キャンセル/実行の 2 ボタン）で新しい作法を発明しない。
            VStack(alignment: .leading, spacing: 12) {
                Text("パスワードを変更するには現在のパスワードを入力してください")
                    .font(.body)
                // 重要な既存の性質: この保存処理はロック以外の設定を先に永続化してからロックを
                // 処理する。ここでキャンセル/失敗しても他タブの変更は既に保存済みなので、
                // 利用者が混乱しないよう明示する。
                Text("他のタブの変更は既に保存済みです。ここではロックの変更のみ行います。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                SecureField("現在のパスワード", text: $changeLockPasswordInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { confirmChangeLock() }

                if let err = changeLockError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("キャンセル") {
                        changeLockPasswordInput = ""
                        changeLockError = nil
                        confirmingChangeLock = false
                    }
                    Spacer()
                    Button("変更") {
                        confirmChangeLock()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(changeLockPasswordInput.isEmpty)
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
            // G25c: salt/hash は組でまとめて消す。書き込みの成功を後続処理の前提にする
            // （失敗を握り潰すと DB にロックが残ったまま UI だけ解除済みになる）。
            // G27a task 8: 無条件削除ではなく、検証に使った `hash` を条件にした compare-and-set。
            // 検証と削除の間に他者（別プロセス・リモート HTTP クライアント）がロックを変更/解除して
            // いれば false が返り、DB は変更されない（TOCTOU を閉じる）。
            do {
                guard try settings.clearLock(expectedHash: hash) else {
                    let alert = NSAlert()
                    alert.messageText = "ロックを解除できませんでした"
                    alert.informativeText = "他の操作でロック設定が変更されたため、書き込みを中止しました。設定を開き直してもう一度お試しください。"
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                    return
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "ロックを解除できませんでした"
                alert.informativeText = "データベースに書き込めませんでした。時間をおいて再度お試しください。\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
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

    /// G27a Task6: 変更確認シートの実処理。confirmDisableLock() と同じ流儀
    /// （検証 → 成功なら実処理・失敗ならシートを閉じずエラー表示のみ）。
    /// 検証は `lockChangeIsAuthorized`（純粋関数・LibraryLock.verify を経由＝定数時間比較）に委ねる。
    /// **不許可のときは settings.setLock を一切呼ばない**（else 分岐は return するだけで
    /// 書き込み経路に触れない — 「拒否された」だけでなく DB が変わらないことの根拠）。
    func confirmChangeLock() {
        guard let hash = settings.lockPasswordHash,
              let salt = settings.lockPasswordSalt else {
            // hash/salt が無いのに confirm sheet が出る状況は想定外 — fallback で sheet 閉じる
            confirmingChangeLock = false
            return
        }
        guard Self.lockChangeIsAuthorized(existingHash: hash, existingSalt: salt,
                                          currentPasswordInput: changeLockPasswordInput) else {
            // 間違い: 入力欄クリア + error 表示（シートは開いたまま再試行できる）
            changeLockPasswordInput = ""
            changeLockError = "パスワードが違います"
            return
        }
        changeLockPasswordInput = ""
        changeLockError = nil
        confirmingChangeLock = false
        // 実際の書き込みは applyNewLock（新規設定と共有）に委ねる。失敗時は
        // applyNewLock がアラート表示済み・ウォッチャー再構成済みなので、ここでは
        // シートを閉じずに抜けるだけで良い。
        // G27a task 8: 検証に使った `hash`（上の guard で読んだ値）を compare-and-set の条件にする。
        guard applyNewLock(isChange: true, expectedHash: hash) else { return }
        appState?.reloadFolderWatcher()
        dismiss()
    }
}
