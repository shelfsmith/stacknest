// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import RemoteClient

/// G25d: 403 のうち「施錠ゲートによる拒否」と「権限不足」を区別する。
///
/// 区別が要る理由: 施錠ゲートの 403 はクライアントが保持しているライブラリトークンが
/// **失効した**ことを意味するので、トークンを捨てて解錠フォームを出し直す必要がある。
/// 一方で権限不足（閲覧トークンで編集を試みた等）の 403 でトークンを捨てると、
/// 単に権限が無いだけのユーザーを解錠フォームへ飛ばしてしまう。
@Suite("403 の種別判定（施錠ゲート vs 権限不足）")
struct LibraryLockedErrorTests {
    @Test("施錠ゲートの印がある 403 は libraryLocked")
    func lockedGateIsDistinguished() {
        #expect(RemoteClientError.forbidden(headers: ["X-Library-Locked": "1"]) == .libraryLocked)
    }

    @Test("印が無い 403 は従来どおり forbidden（権限不足）")
    func plainForbiddenStaysForbidden() {
        #expect(RemoteClientError.forbidden(headers: [:]) == .forbidden)
        #expect(RemoteClientError.forbidden(headers: ["Content-Type": "application/json"]) == .forbidden)
    }

    @Test("ヘッダ名の大文字小文字を問わない")
    func headerLookupIsCaseInsensitive() {
        #expect(RemoteClientError.forbidden(headers: ["x-library-locked": "1"]) == .libraryLocked)
    }

    @Test("印の値が 1 以外なら施錠ゲートとみなさない")
    func onlyExplicitFlagCounts() {
        #expect(RemoteClientError.forbidden(headers: ["X-Library-Locked": "0"]) == .forbidden)
    }
}
