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

    /// 保存キーの文字列を固定する。読み書きが同じ定数を使うので、**キーを改名しても
    /// 往復テストは素通りする**（最終レビューで穴として見つかった）。改名すると
    /// **ユーザーの保存済みの設定が黙って既定へ戻る**ので、外から literal で書いて確かめる。
    @Test func theStorageKeysAreTheOnesAlreadyShipped() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        ud.set("square", forKey: "viewerLoupeShape")
        ud.set(4.0, forKey: "viewerLoupeMagnification")

        let s = ViewerSettings(defaults: ud)
        #expect(s.loupeShape == .square, "保存キー viewerLoupeShape を変えてはいけない")
        #expect(s.loupeMagnification == 4.0, "保存キー viewerLoupeMagnification を変えてはいけない")
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

    /// 範囲外を代入したときも、通知は **1 回だけ**であること。
    ///
    /// clamp は「範囲外なら clamped 値で再代入して didSet を再発火させる」方式で、
    /// 再代入したら **`return` して以降の永続化と通知をスキップする**のが要。
    /// この `return` を落とすと通知が 2 回飛び、**開いている全ビューア窓が 2 度再描画される**。
    /// レビューで「`return` を消しても既存テストが全部通る」穴として見つかった。
    @Test func outOfRangeAssignmentPostsTheNotificationExactlyOnce() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: ud)

        var received = 0
        let token = NotificationCenter.default.addObserver(
            forName: .viewerLoupeAppearanceChanged, object: nil, queue: nil) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        s.loupeMagnification = 99      // 範囲外 → clamp して再代入が走る
        #expect(s.loupeMagnification == Double(LoupeMagnification.range.upperBound))
        #expect(received == 1, "clamp の再代入で通知が 2 回飛んではいけない")
    }

    /// 初期化のたびに全ウィンドウが再描画されては無駄なので、`init` からは通知が飛ばないこと。
    @Test func initDoesNotPostTheNotification() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }

        var received = 0
        let token = NotificationCenter.default.addObserver(
            forName: .viewerLoupeAppearanceChanged, object: nil, queue: nil) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        _ = ViewerSettings(defaults: ud)
        #expect(received == 0, "イニシャライザ内の初回代入で didSet は走らない")
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

    @Test func theSizeSurvivesARoundTripAndDefaultsToMedium() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        #expect(ViewerSettings(defaults: ud).loupeSize == .medium, "未保存なら中")

        let s = ViewerSettings(defaults: ud)
        s.loupeSize = .large
        #expect(ViewerSettings(defaults: ud).loupeSize == .large)
    }

    @Test func anUnknownStoredSizeFallsBackToMedium() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        ud.set("gigantic", forKey: "viewerLoupeSize")
        #expect(ViewerSettings(defaults: ud).loupeSize == .medium)
    }

    @Test func changingTheSizePostsTheAppearanceNotification() {
        let (ud, name) = freshDefaults(); defer { ud.removePersistentDomain(forName: name) }
        let s = ViewerSettings(defaults: ud)
        var received = 0
        let token = NotificationCenter.default.addObserver(
            forName: .viewerLoupeAppearanceChanged, object: nil, queue: nil) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        s.loupeSize = .small
        #expect(received == 1)
    }
}
