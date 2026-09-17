// SPDX-License-Identifier: MIT
import Foundation
import Testing
import EPUBAdapter
@testable import AppCore

@Suite("G54-S3: ページ送りの演出とノンブルの設定")
@MainActor
struct ViewerSettingsPageTurnTests {
    private func freshDefaults() -> UserDefaults {
        let name = "g54s3-page-turn-\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: name)!
        ud.removePersistentDomain(forName: name)
        return ud
    }

    @Test func defaultsAreOffAndHidden() {
        let s = ViewerSettings(defaults: freshDefaults())
        #expect(s.pageTurnStyle == .off)
        #expect(s.showsEPUBFolio == false)
    }

    @Test func persistsAndReloads() {
        let ud = freshDefaults()
        let s = ViewerSettings(defaults: ud)
        s.pageTurnStyle = .fade
        s.showsEPUBFolio = true
        #expect(ud.string(forKey: "pageTurnStyle") == "fade")
        #expect(ud.bool(forKey: "showsEPUBFolio") == true)
        let reloaded = ViewerSettings(defaults: ud)
        #expect(reloaded.pageTurnStyle == .fade)
        #expect(reloaded.showsEPUBFolio == true)
    }

    @Test func unreadableStoredStyleFallsBackToOff() {
        let ud = freshDefaults()
        ud.set("curl", forKey: "pageTurnStyle")
        #expect(ViewerSettings(defaults: ud).pageTurnStyle == .off)
    }

    @Test func eachChangePostsTheNotificationOnce() {
        let s = ViewerSettings(defaults: freshDefaults())
        var received = 0
        let token = NotificationCenter.default.addObserver(
            forName: .viewerEPUBPresentationChanged, object: nil, queue: nil) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        s.pageTurnStyle = .slide
        #expect(received == 1)
        s.showsEPUBFolio = true
        #expect(received == 2)
    }

    @Test func initDoesNotPostTheNotification() {
        let ud = freshDefaults()
        ud.set("slide", forKey: "pageTurnStyle")
        var received = 0
        let token = NotificationCenter.default.addObserver(
            forName: .viewerEPUBPresentationChanged, object: nil, queue: nil) { _ in received += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = ViewerSettings(defaults: ud)
        #expect(received == 0)
    }
}
