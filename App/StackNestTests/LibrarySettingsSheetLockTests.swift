// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNest
import AppCore

/// G27a Task6: `LibrarySettingsSheet` の保存直前に、パスワード**変更**にも現パスワード確認を
/// 要求するようにした（解除にはもともと要求していた非対称性の解消）。
///
/// **なぜ純粋関数を対象にテストするか**: 当初は `LibrarySettingsSheet`（SwiftUI View 構造体）を
/// 直接構築し `@State`（`passwordInput` / `changeLockPasswordInput` 等）を手動で書き換えて
/// `confirmChangeLock()` を呼ぶ形で書いたが、**ライブビューヒエラルキーにマウントしていないと
/// `@State` への書き込みが後続のメソッド呼び出しへ反映されないことを実測した**
/// （xcodebuild test で実行し、書いたはずの値が別メソッド内で空文字列のまま読めた・
/// SwiftUI の未サポート挙動）。そこで判定ロジック自体を `@State` から独立した純粋関数
/// `LibrarySettingsSheet.lockChangeIsAuthorized` へ切り出し、そちらをテストする
/// （切り出しの根拠は `LibrarySettingsSheet.swift` のコメント参照）。
///
/// **「拒否＝DB 不変」の根拠**: `confirmChangeLock()`（`LibrarySettingsSheet+Lock.swift`）は
/// `lockChangeIsAuthorized` が false を返す分岐で `return` するだけで、`settings.setLock` を
/// 一切呼ばない（コードを読めば分かる制御フロー上の保証）。したがって、この純粋関数が
/// 「誤ったパスワードで false を返す」ことをここで確認すれば、GUI 側でも「拒否＝ハッシュ不変」
/// が成り立つことの根拠になる（DB 書き込みそのものは AppCoreTests/LibrarySettingsLockTests と
/// Tests/LibraryServerTests/LockEndpointTests が別途カバー済み）。
@Suite("LibrarySettingsSheet.lockChangeIsAuthorized（ロック変更の現パスワード確認・純粋関数）")
struct LibrarySettingsSheetLockTests {
    /// brief item 1 の GUI 側回帰ガード: ロックが無い状態（existingHash/existingSalt が nil）
    /// からの新規設定は、どんな入力でも常に許可される（現パスワード不要のまま）。
    @Test func noExistingLockIsAlwaysAuthorized() {
        #expect(LibrarySettingsSheet.lockChangeIsAuthorized(
            existingHash: nil, existingSalt: nil, currentPasswordInput: ""))
        #expect(LibrarySettingsSheet.lockChangeIsAuthorized(
            existingHash: nil, existingSalt: nil, currentPasswordInput: "anything"))
    }

    /// brief item 3: 既存ロックに対し正しい現パスワードを渡すと許可される。
    @Test func correctCurrentPasswordIsAuthorized() {
        let salt = LibraryLock.generateSalt()
        let hash = LibraryLock.computeHash(password: "original", saltHex: salt)
        #expect(LibrarySettingsSheet.lockChangeIsAuthorized(
            existingHash: hash, existingSalt: salt, currentPasswordInput: "original"))
    }

    /// brief item 2 の核心: 既存ロックに対し**誤った**現パスワードを渡すと拒否される。
    /// `confirmChangeLock()` はこの false を受けて `settings.setLock` を呼ばずに return する
    /// （制御フロー上の保証。上記スイート doc 参照）ため、これは実質「拒否＝DB 不変」の根拠になる。
    @Test func wrongCurrentPasswordIsRejected() {
        let salt = LibraryLock.generateSalt()
        let hash = LibraryLock.computeHash(password: "original", saltHex: salt)
        #expect(!LibrarySettingsSheet.lockChangeIsAuthorized(
            existingHash: hash, existingSalt: salt, currentPasswordInput: "wrongpw"))
    }

    /// 空文字の現パスワードも同様に拒否される（誤って「未入力＝許可」にならないこと）。
    @Test func emptyCurrentPasswordIsRejectedWhenLockExists() {
        let salt = LibraryLock.generateSalt()
        let hash = LibraryLock.computeHash(password: "original", saltHex: salt)
        #expect(!LibrarySettingsSheet.lockChangeIsAuthorized(
            existingHash: hash, existingSalt: salt, currentPasswordInput: ""))
    }

    /// 一方の値だけ nil（本来 setLock/clearLock は組で書くので想定外の中間状態）は拒否側に倒れる
    /// — 無条件許可の対象を「本当に未設定（両方 nil）」だけに絞るフェイルセーフの確認。
    /// `confirmChangeLock()` 自体はこの形では呼ばれない（呼び出し元の guard が両方揃っていない
    /// 限り先へ進めない設計）が、関数単体の契約として拒否側であることを固定する。
    @Test func partiallyMissingExistingCredentialFailsClosed() {
        let salt = LibraryLock.generateSalt()
        #expect(!LibrarySettingsSheet.lockChangeIsAuthorized(
            existingHash: nil, existingSalt: salt, currentPasswordInput: "whatever"))
        let hash = LibraryLock.computeHash(password: "original", saltHex: salt)
        #expect(!LibrarySettingsSheet.lockChangeIsAuthorized(
            existingHash: hash, existingSalt: nil, currentPasswordInput: "whatever"))
    }
}
