// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

/// G38 final review C-1: `ViewerKeyBindings.load()` は decode した保存済みマップをそのまま返すだけで、
/// defaults に新しいアクション（toggleLoupe 等）のキーを足しても既存ユーザーには一生届かなかった
/// （レビュアー実測: 保存済み `characterMap` が 24 件で "l" を含まない Mac で `l` が完全に無反応）。
/// `fillMissingActionsFromDefaults()` がこの穴を汎用的に塞ぐことを確認する。
@Suite("ViewerKeyBindings.load() の defaults マージ（G38 final review C-1）")
struct ViewerKeyBindingsLoadMergeTests {
    /// 保存済みマップが登場前の新アクション（toggleLoupe）を知らない旧ユーザーを模する。
    /// `load()` は defaults の既定キー "l" を補い、`toggleLoupe` が実際に押せるようにならなければならない。
    @Test func loadFillsMissingActionDefaultBinding() throws {
        let suite = "test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }

        var old = ViewerKeyBindings.defaults
        old.characterMap["l"] = nil   // toggleLoupe 登場前に保存された「24 件・l 無し」を再現
        let data = try JSONEncoder().encode(old)
        ud.set(data, forKey: ViewerKeyBindings.userDefaultsKey)

        let loaded = ViewerKeyBindings.load(ud)
        #expect(loaded.action(forCharacter: "l") == .toggleLoupe,
                "defaults にしかない新アクションのキーが、保存済みユーザーにも届かなければならない")
    }

    /// ユーザーが独自に toggleLoupe を別キーへ再割当していた場合、`load()` は defaults の "l" を
    /// 押し付けて上書きしてはいけない（defaults 側は既存の割当と衝突するので補わない）。
    @Test func loadDoesNotOverwriteUserRebind() throws {
        let suite = "test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }

        var old = ViewerKeyBindings.defaults
        old.characterMap["l"] = nil
        old.characterMap["m"] = .toggleLoupe   // ユーザーが独自に "m" へ再割当済み

        let data = try JSONEncoder().encode(old)
        ud.set(data, forKey: ViewerKeyBindings.userDefaultsKey)

        let loaded = ViewerKeyBindings.load(ud)
        #expect(loaded.action(forCharacter: "m") == .toggleLoupe,
                "ユーザーが再割当した既存バインドは維持されなければならない")
        #expect(loaded.action(forCharacter: "l") == nil,
                "defaults の l を後から足して、ユーザーの再割当を上書き／併存させてはいけない")
    }

    /// defaults の既定キーが既に別アクションに使われていたら、奪わずそのアクションは未バインドのまま残す。
    @Test func loadDoesNotStealKeyUsedByAnotherAction() throws {
        let suite = "test.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }

        var old = ViewerKeyBindings.defaults
        old.characterMap["l"] = .cycleEndOfBookBehavior   // 別アクションが "l" を既に使用中

        let data = try JSONEncoder().encode(old)
        ud.set(data, forKey: ViewerKeyBindings.userDefaultsKey)

        let loaded = ViewerKeyBindings.load(ud)
        #expect(loaded.action(forCharacter: "l") == .cycleEndOfBookBehavior,
                "l は既に他アクションが使用中なので奪ってはいけない")
        #expect(loaded.boundBindings(for: .toggleLoupe).isEmpty,
                "唯一の defaults キーが衝突で補えない場合、そのアクションは未バインドのまま残る")
    }
}

/// G38 再レビュー Important #1: C-1 の修正（未バインドのアクションへ defaults を補う）は、
/// **ユーザーが意図的に外したキーまで復活させてしまう**という退行を持ち込んでいた。
/// 設定画面のチップ「×」は最後の 1 個も削除でき（`KeyBindingsSettingsView.swift`）、
/// 保存されるのは「空」——それを次の `load()` が「未バインド＝補うべき」と読み違えるため、
/// 例えば「誤爆するので外した `s`（スライドショー）」がビューアを開き直すたびに戻ってきた。
///
/// `knownActions`（保存時点で既知だったアクション）を永続化して両者を分ける。
@Suite("ViewerKeyBindings の削除の永続（G38 再レビュー Important #1）")
struct ViewerKeyBindingsDeletionPersistenceTests {
    private func freshSuite() -> (UserDefaults, String) {
        let name = "test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// 既知のアクションからユーザーが唯一のキーを外した保存データは、そのまま維持される。
    @Test func loadKeepsAnIntentionallyDeletedBindingDeleted() throws {
        let (ud, name) = freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        var saved = ViewerKeyBindings.defaults
        saved.knownActions = ViewerKeyBindings.allActionKeys   // 保存時に全アクションを既知として記録済み
        saved.remove(.character("s"), from: .toggleAutoAdvance)  // ユーザーが意図的に外した
        ud.set(try JSONEncoder().encode(saved), forKey: ViewerKeyBindings.userDefaultsKey)

        let loaded = ViewerKeyBindings.load(ud)
        #expect(loaded.action(forCharacter: "s") == nil,
                "ユーザーが意図的に外したキーを load が復活させてはいけない")
        #expect(loaded.boundBindings(for: .toggleAutoAdvance).isEmpty,
                "そのアクションは未バインドのまま残らなければならない")
    }

    /// 移行の核心 —— 同じ 1 回の load で「新アクションは補う」「外した既知アクションは戻さない」を
    /// 両立できること。これが崩れると C-1 と Important #1 のどちらかが必ず再発する。
    @Test func loadFillsOnlyActionsThatWereUnknownWhenSaved() throws {
        let (ud, name) = freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        var saved = ViewerKeyBindings.defaults
        // toggleLoupe 登場「前」に保存された想定: 既知集合から toggleLoupe だけを欠く
        saved.knownActions = ViewerKeyBindings.allActionKeys.subtracting([ViewerAction.toggleLoupe.rawValue])
        saved.characterMap["l"] = nil                            // 当時は存在しなかったキー
        saved.remove(.character("s"), from: .toggleAutoAdvance)   // 当時ユーザーが外したキー
        ud.set(try JSONEncoder().encode(saved), forKey: ViewerKeyBindings.userDefaultsKey)

        let loaded = ViewerKeyBindings.load(ud)
        #expect(loaded.action(forCharacter: "l") == .toggleLoupe,
                "保存時に未知だったアクションのキーは補わなければならない")
        #expect(loaded.action(forCharacter: "s") == nil,
                "保存時に既知だったアクションの削除は維持しなければならない")
    }

    /// 旧データ（`knownActions` なし）の移行は 1 度きり。1 回目は従来どおり一律に補い、
    /// その結果を保存すると、2 回目以降の削除は残る。
    @Test func legacyDataMigratesOnceThenDeletionsStick() throws {
        let (ud, name) = freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        var legacy = ViewerKeyBindings.defaults
        legacy.knownActions = nil        // G38 以前の保存データ
        legacy.characterMap["l"] = nil
        ud.set(try JSONEncoder().encode(legacy), forKey: ViewerKeyBindings.userDefaultsKey)

        // 1 回目: C-1 の穴を塞ぐ従来どおりの挙動
        var migrated = ViewerKeyBindings.load(ud)
        #expect(migrated.action(forCharacter: "l") == .toggleLoupe)
        #expect(migrated.knownActions == ViewerKeyBindings.allActionKeys,
                "load は移行後に現在の全アクションを既知として刻まなければならない")

        // ユーザーが設定画面でキーを外して保存する（KeyBindingsSettingsView.persist() 相当）
        migrated.remove(.character("s"), from: .toggleAutoAdvance)
        migrated.save(ud)

        // 2 回目: 削除が残る
        let reloaded = ViewerKeyBindings.load(ud)
        #expect(reloaded.action(forCharacter: "s") == nil,
                "移行後に外したキーは、次回 load で戻ってはいけない")
        #expect(reloaded.action(forCharacter: "l") == .toggleLoupe,
                "移行で補ったキーは維持されなければならない")
    }

    /// 未保存の新規ユーザーも同じ保護を受ける。`.defaults` をそのまま返すと knownActions が nil のままで、
    /// 「初めて設定を開いてキーを 1 つ外した」ユーザーの削除が次回 load で巻き戻る。
    @Test func firstRunUserCanDeleteABindingAndHaveItStick() throws {
        let (ud, name) = freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        var fresh = ViewerKeyBindings.load(ud)   // 未保存
        #expect(fresh.knownActions == ViewerKeyBindings.allActionKeys,
                "未保存パスでも既知集合を刻まなければならない")

        fresh.remove(.character("s"), from: .toggleAutoAdvance)
        fresh.save(ud)

        #expect(ViewerKeyBindings.load(ud).action(forCharacter: "s") == nil,
                "新規ユーザーの削除も次回 load で戻ってはいけない")
    }

    /// `resetAll()` は `self = .defaults`（knownActions は nil）なので、刻み直さないと
    /// 「全部既定に戻す → キーを 1 つ外す」の削除が巻き戻る。
    @Test func resetAllStampsKnownActionsSoLaterDeletionsStick() throws {
        let (ud, name) = freshSuite()
        defer { ud.removePersistentDomain(forName: name) }

        var b = ViewerKeyBindings.load(ud)
        b.resetAll()
        #expect(b.knownActions == ViewerKeyBindings.allActionKeys,
                "resetAll は既知集合を刻み直さなければならない")

        b.remove(.character("s"), from: .toggleAutoAdvance)
        b.save(ud)

        #expect(ViewerKeyBindings.load(ud).action(forCharacter: "s") == nil,
                "resetAll の直後に外したキーも、次回 load で戻ってはいけない")
    }
}
