// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI
import StackNestL10n

/// アクセスグラント（トークン + tier + スコープ）の 1 件分のレコード。
public struct Grant: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var label: String
    public var token: String
    public var tier: AccessTier
    public var scope: GrantScope
    public let createdAt: Date
    public init(id: String, label: String, token: String, tier: AccessTier, scope: GrantScope, createdAt: Date) {
        self.id = id; self.label = label; self.token = token; self.tier = tier; self.scope = scope; self.createdAt = createdAt
    }

    /// 画面表示用のラベル（G55）。保存値 `label` は変えず、種まきした既定ラベルのときだけ訳す。
    public var displayLabel: String { GrantStore.displayLabel(for: label) }
}

/// UserDefaults ベースのグラント CRUD + 初回移行ヘルパ。
public enum GrantStore {
    public static let key = "server_grants"

    /// `migrateIfNeeded`／`syncDefaultGrants` が種まきする既定ラベル（UserDefaults の保存値・G55 で不変）。
    static let seededLabels: Set<String> = ["(既定) 閲覧", "(既定) 編集"]  // l10n:ignore stored seed values (language-independent); display via displayLabel(for:)

    /// 画面表示用のラベル（G55）。保存値がちょうど種まきの既定ラベルなら現在の言語に訳し、
    /// それ以外（利用者が付けた名前・改名後の値）はそのまま返す。**保存・照合には使わない。**
    public static func displayLabel(for storedLabel: String) -> String {
        seededLabels.contains(storedLabel) ? L10n.text(storedLabel) : storedLabel
    }
    public static func list(defaults: UserDefaults = .standard) -> [Grant] {
        guard let data = defaults.data(forKey: key),
              let arr = try? JSONDecoder().decode([Grant].self, from: data) else { return [] }
        return arr
    }
    private static func save(_ grants: [Grant], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(grants) { defaults.set(data, forKey: key) }
    }
    public static func add(_ g: Grant, defaults: UserDefaults = .standard) {
        var arr = list(defaults: defaults); arr.append(g); save(arr, defaults: defaults)
    }
    public static func update(_ g: Grant, defaults: UserDefaults = .standard) {
        var arr = list(defaults: defaults)
        if let i = arr.firstIndex(where: { $0.id == g.id }) { arr[i] = g; save(arr, defaults: defaults) }
    }
    public static func delete(id: String, defaults: UserDefaults = .standard) {
        save(list(defaults: defaults).filter { $0.id != id }, defaults: defaults)
    }
    public static func find(token: String, defaults: UserDefaults = .standard) -> Grant? {
        list(defaults: defaults).first { $0.token == token }
    }
    /// 初期化/移行の判断が一度でも済んだかを示す永続マーカー。
    static let migratedKey = "server_grants_migrated"

    /// 旧来の readToken / editToken を GrantStore 形式に **1 度だけ** 移行する。
    /// C-③b-2 で default-read/default-edit も削除可能になったため、"list が空か" だけで判定すると
    /// 全トークン削除後の再起動で凍結された旧トークンが意図せず復活し「取り消し不可」の約束に反する。
    /// そこで**一度きりのマーカー**で判定する: 一度でも初期化判断が済んでいれば二度と種まきしない。
    /// - 新規: マーカー未設定＋list 空 → default-read(+edit) を種まき。
    /// - 既存(B2 で移行済): マーカー未設定＋list 非空 → 種まきせずマーカーだけ立てる。
    /// - 全トークン削除後: マーカー設定済 → 何もしない（復活させない）。
    public static func migrateIfNeeded(readToken: String, editToken: String?, now: Date = Date(timeIntervalSince1970: 0), defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        guard list(defaults: defaults).isEmpty else { return }
        var grants: [Grant] = [Grant(id: "default-read", label: "(既定) 閲覧", token: readToken, tier: .read, scope: .all, createdAt: now)]  // l10n:ignore stored UserDefaults grant label (seeded once; user-renamable, parity with FilenameFormatPreset default name)
        if let editToken { grants.append(Grant(id: "default-edit", label: "(既定) 編集", token: editToken, tier: .edit, scope: .all, createdAt: now)) }  // l10n:ignore stored UserDefaults grant label (seeded once; user-renamable)
        save(grants, defaults: defaults)
    }

    /// 既定グラント(default-read / default-edit)のトークンを現在の ServerPreferences 値へ同期する。
    /// トークン再生成・編集トークン無効化を grant 認可へ反映し、**旧トークンを失効**させる（rotation/revocation 修復）。
    /// ユーザーが作成したカスタムグラントは触らない。
    /// 注: **C-③b-2（共有トークン一本化）以降、本番からは呼び出されない**（grant を唯一源にしたため
    /// トークン操作は共有トークン UI＝GrantStore 直接操作に一本化）。テストのみが参照。将来 headless 等で再利用可。
    public static func syncDefaultGrants(readToken: String, editToken: String?, now: Date = Date(timeIntervalSince1970: 0), defaults: UserDefaults = .standard) {
        var arr = list(defaults: defaults)
        var changed = false
        if let i = arr.firstIndex(where: { $0.id == "default-read" }), arr[i].token != readToken {
            arr[i].token = readToken; changed = true
        }
        if let editToken {
            if let i = arr.firstIndex(where: { $0.id == "default-edit" }) {
                if arr[i].token != editToken { arr[i].token = editToken; changed = true }
            } else {
                arr.append(Grant(id: "default-edit", label: "(既定) 編集", token: editToken, tier: .edit, scope: .all, createdAt: now)); changed = true  // l10n:ignore stored UserDefaults grant label (seeded once; user-renamable)
            }
        } else if arr.contains(where: { $0.id == "default-edit" }) {
            arr.removeAll { $0.id == "default-edit" }; changed = true   // 編集トークン無効化を反映
        }
        if changed { save(arr, defaults: defaults) }
    }
}
