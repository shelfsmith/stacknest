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
    /// G25c: 引数は**実際に検証が通ったハッシュ**。現在値でアームすると、検証中に外部から
    /// パスワードを差し替えられた場合に「ユーザーが一度も検証していないパスワード」でアームされ、
    /// 以後の生体認証だけでそれを解錠できてしまう。検証した値でアームすれば、差し替えられていた場合は
    /// `decideBiometricUnlock` が armed≠current を検出して `requirePassword` に落ちる（fail-closed）。
    let armThisMachine: (String) -> Void
    /// G25c: 解錠成功を通知する。引数は**実際に検証が通ったハッシュ**（呼出側はこれを記録する）。
    /// 「現在のハッシュ」ではなく検証したものを渡すこと — 生体認証はプロンプト表示中に外部から
    /// パスワードを差し替えられる余地があり、現在値を記録すると検証していないハッシュを
    /// 解錠済みとして扱ってしまう。
    let onUnlock: (String) -> Void
    let onCancel: () -> Void
    /// G23 (#8): 保存値が旧形式だったとき、新形式（PBKDF2）のハッシュを親へ渡す。
    /// このシートは LibrarySettings を持たないため、保存は親の責務。
    /// G25c: 引数は (この試行で照合したハッシュ, 移行後のハッシュ)。**戻り値は実際に書き戻したか。**
    /// 親は `shouldPersistHashUpgrade` で compare-and-set し、検証中に差し替えられていたら false を返す
    /// （無条件に書き戻すと外部が設定した新パスワードを旧パスワード由来の値で巻き戻してしまう）。
    var onUpgradeHash: ((String, String) -> Bool)? = nil

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
        switch LibraryLock.verifyAndUpgrade(password: password, saltHex: salt, against: hash) {
        case .ok(let upgraded):
            // G23 (#8): 旧形式だった場合はここで新形式へ移行する（平文が手に入るのはこの瞬間だけ）。
            // G25c: 親は検証中の差し替えを検出したら書き戻しを拒否して false を返す。その場合は
            // 移行後の値を「有効」とみなしてはならない（DB には入っていない）。
            var effectiveHash = hash
            if let upgraded, onUpgradeHash?(hash, upgraded) == true {
                effectiveHash = upgraded
            }
            // パスワード証明成功: 生体認証有効ならこの Mac を自動アーム（平文は保存されない）。
            // アームも通知も **検証した値**（移行が成立したならその結果）で行う。
            if useBiometric {
                armThisMachine(effectiveHash)
            }
            onUnlock(effectiveHash)
        case .failed:
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
                // decideBiometricUnlock が照合したのはこの `hash`。プロンプト表示中に
                // 外部から差し替えられていた場合、記録した値と現在値が食い違うので
                // AppState.isUnlocked は自動的に false のままになる（＝素通りしない）。
                onUnlock(hash)
            case .requirePassword:
                logger.info("tryBiometric: not armed on this machine (or password changed) — require password")
                showPasswordHint = true
            }
        }
    }
}
