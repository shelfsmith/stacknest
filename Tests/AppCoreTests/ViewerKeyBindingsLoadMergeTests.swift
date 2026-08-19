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
