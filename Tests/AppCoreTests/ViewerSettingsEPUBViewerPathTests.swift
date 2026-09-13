// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

/// G54-S2b: EPUB だけ外部ビューアを別に指定できる。
/// `BookCategory` は `pdf` `epub` `txt` `md` `rtf` をまとめて `.text` に入れるので、
/// 分類を増やさずに**解決の 1 か所**で拡張子を見て分ける。
@MainActor
@Suite("G54-S2b: EPUB 専用の外部ビューア指定")
struct ViewerSettingsEPUBViewerPathTests {
    private func makeSettings() -> ViewerSettings {
        ViewerSettings(defaults: UserDefaults(suiteName: "g54s2b-\(UUID().uuidString)")!)
    }

    @Test("既定は未設定")
    func defaultsToNil() {
        #expect(makeSettings().epubViewerAppPath == nil)
    }

    @Test("EPUB の専用指定が在れば、それを返す")
    func epubOverrideWins() {
        let s = makeSettings()
        s.externalViewerAppPath = "/Applications/Default.app"
        s.categoryViewerPaths[.text] = "/Applications/Text.app"
        s.epubViewerAppPath = "/Applications/Books.app"
        #expect(s.resolvedViewerPath(forPath: "/tmp/a.epub", category: .text) == "/Applications/Books.app")
    }

    @Test("大文字の拡張子でも効く")
    func caseInsensitive() {
        let s = makeSettings()
        s.epubViewerAppPath = "/Applications/Books.app"
        #expect(s.resolvedViewerPath(forPath: "/tmp/A.EPUB", category: .text) == "/Applications/Books.app")
    }

    @Test("専用指定が無ければ テキスト の指定へ落ちる")
    func fallsBackToCategory() {
        let s = makeSettings()
        s.categoryViewerPaths[.text] = "/Applications/Text.app"
        #expect(s.resolvedViewerPath(forPath: "/tmp/a.epub", category: .text) == "/Applications/Text.app")
    }

    @Test("専用指定が空文字でも テキスト の指定へ落ちる")
    func emptyOverrideIsIgnored() {
        let s = makeSettings()
        s.epubViewerAppPath = ""
        s.categoryViewerPaths[.text] = "/Applications/Text.app"
        #expect(s.resolvedViewerPath(forPath: "/tmp/a.epub", category: .text) == "/Applications/Text.app")
    }

    @Test("どちらも無ければ既定へ落ちる")
    func fallsBackToDefault() {
        let s = makeSettings()
        s.externalViewerAppPath = "/Applications/Default.app"
        #expect(s.resolvedViewerPath(forPath: "/tmp/a.epub", category: .text) == "/Applications/Default.app")
    }

    @Test("PDF と txt は EPUB の指定に引っぱられない")
    func otherTextFormatsAreUnaffected() {
        let s = makeSettings()
        s.categoryViewerPaths[.text] = "/Applications/Text.app"
        s.epubViewerAppPath = "/Applications/Books.app"
        #expect(s.resolvedViewerPath(forPath: "/tmp/a.pdf", category: .text) == "/Applications/Text.app")
        #expect(s.resolvedViewerPath(forPath: "/tmp/a.txt", category: .text) == "/Applications/Text.app")
    }

    @Test("EPUB 以外の分類にも影響しない")
    func nonTextCategoriesAreUnaffected() {
        let s = makeSettings()
        s.categoryViewerPaths[.archive] = "/Applications/Comic.app"
        s.epubViewerAppPath = "/Applications/Books.app"
        #expect(s.resolvedViewerPath(forPath: "/tmp/a.zip", category: .archive) == "/Applications/Comic.app")
    }

    @Test("拡張子が epub でも分類が folder なら専用指定を見ない")
    func folderNamedLikeEPUBIsUnaffected() {
        let s = makeSettings()
        s.categoryViewerPaths[.folder] = "/Applications/Folder.app"
        s.epubViewerAppPath = "/Applications/Books.app"
        #expect(s.resolvedViewerPath(forPath: "/tmp/展開済み.epub", category: .folder) == "/Applications/Folder.app")
    }

    @Test("専用指定が永続化される")
    func persists() {
        let name = "g54s2b-persist-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let s = ViewerSettings(defaults: suite)
        s.epubViewerAppPath = "/Applications/Books.app"
        #expect(suite.string(forKey: "epubViewerAppPath") == "/Applications/Books.app")
        #expect(ViewerSettings(defaults: suite).epubViewerAppPath == "/Applications/Books.app")
    }

    @Test("nil を入れるとキーが消える")
    func clearingRemovesTheKey() {
        let name = "g54s2b-clear-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        let s = ViewerSettings(defaults: suite)
        s.epubViewerAppPath = "/Applications/Books.app"
        s.epubViewerAppPath = nil
        #expect(suite.object(forKey: "epubViewerAppPath") == nil)
        #expect(ViewerSettings(defaults: suite).epubViewerAppPath == nil)
    }
}
