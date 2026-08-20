// SPDX-License-Identifier: MIT
import Testing
import Foundation
import CoreGraphics
@testable import AppCore

@Suite("ViewerSettings のルーペ設定（G40）")
@MainActor
struct ViewerSettingsLoupeTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func firstRunUsesTheDefaults() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: ud)
        #expect(s.loupeMagnification == Double(LoupeMagnification.defaultValue))
        #expect(s.loupeShape == LoupeShape.defaultValue)
    }

    @Test func valuesSurviveARoundTrip() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: ud)
        s.loupeMagnification = 4.5
        s.loupeShape = .square

        let reloaded = ViewerSettings(defaults: ud)
        #expect(reloaded.loupeMagnification == 4.5)
        #expect(reloaded.loupeShape == .square)
    }

    /// 範囲外を代入したら即座に畳まれること（UI からも CLI からも壊れた値が入りうる）。
    @Test func assigningOutOfRangeClampsImmediately() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: ud)
        s.loupeMagnification = 99
        #expect(s.loupeMagnification == Double(LoupeMagnification.range.upperBound))
        s.loupeMagnification = 0.1
        #expect(s.loupeMagnification == Double(LoupeMagnification.range.lowerBound))
    }

    /// 保存済みの値が壊れていても（範囲外・別アプリが書いた等）、読み出しで畳む。
    @Test func loadingAStoredOutOfRangeValueClampsIt() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        ud.set(42.0, forKey: "viewerLoupeMagnification")
        ud.set("triangle", forKey: "viewerLoupeShape")
        let s = ViewerSettings(defaults: ud)
        #expect(s.loupeMagnification == Double(LoupeMagnification.range.upperBound))
        #expect(s.loupeShape == LoupeShape.defaultValue, "未知の形は既定へ")
    }

    /// ★ 開いているビューア窓へ変更を届けるための通知。
    /// キーバインドは通知を購読しておらず「変えても開いている窓に効かない」欠陥がある（G38 smoke）。
    /// 同じ誤りを繰り返さないための土台なので、発行されることをテストで固定する。
    @Test func changingTheAppearancePostsANotification() async {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: ud)

        var received = 0
        let token = NotificationCenter.default.addObserver(
            forName: .viewerLoupeAppearanceChanged, object: nil, queue: nil) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        s.loupeShape = .square
        s.loupeMagnification = 3.0
        #expect(received == 2)
    }
}
