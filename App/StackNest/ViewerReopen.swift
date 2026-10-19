// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import Foundation
import LibraryStore
import os

/// 外部ビューアからの「この本をもう一度渡して」（`stacknest://viewer/reopen?…`。StackNestViewerKit の
/// `StackNestReopenRequest`・形式の文書「本をもう一度渡してもらう」）。
///
/// 参照ファイルは残しても後から開き直せない（鍵の期限・ポートと中継の id が渡すたびに変わる・StackNest が動いていない
/// こともある）ので、外部ビューアは履歴や保存データから本を開き直すとき、この URL を開く。StackNest は動いていなければ
/// macOS が起動する。頼みにはライブラリの UUID・本の番号・本の同一性（manifest の `bookIdentity`）が入り、鍵は入らない。
///
/// 渡すのは次のときだけ（どれかに外れたら渡さず、知らせるか黙る）:
/// - 頼んだアプリが、今その本を渡す外部ビューア（`referenceViewer(for:)` のアプリ）である。どのアプリでも URL は開けるので、
///   頼みの Apple Event の送り手で確かめる。送り手が分からなければ渡さない。
/// - ライブラリが開いている、または外部ビューアへ本を渡したことがあって場所を覚えている（`ViewerReopenLibraries`）。
///   開いていなければ開く。施錠していれば解錠を待つ（解錠の画面が出る。⌘⇧O の続きから開くのと同じ規則）。
/// - 番号の本が今もあり、同一性が同じ（本の番号は使い回されるので、別の本を開かない）。
/// 渡し方はライブラリの窓で選んで開いたときと同じ（`openInExternalViewerSyncing`。開くページは保存済みの読書位置）。
@MainActor
enum ViewerReopen {
    static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "ViewerReopen")

    /// 頼みの URL か（`application(_:open:)` が振り分ける）。
    static func isRequestURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == StackNestReopenRequest.scheme
    }

    /// 頼みを受ける。ライブラリの窓を開く（開いている窓へ渡す）ことになったら true（起動時の題名の画面を出さない判断に使う）。
    ///
    /// **最初に送り手を確かめる**: どのアプリでも URL は開けるので、送り手が設定の外部ビューア（`isConfiguredViewer`）でなければ、
    /// ライブラリを開く・解錠の画面・警告・知らせのどれも出さずにログだけ残す（ほかのアプリに StackNest を操らせない・ライブラリや
    /// 本があるかを知らせで探らせない）。本ごとの確かめ（その本を渡す外部ビューアか・同一性）は `handleViewerReopen`。
    @discardableResult
    static func handle(_ url: URL, sender: URL?, settings: ViewerSettings = .shared) -> Bool {
        guard let request = StackNestReopenRequest(url: url) else {
            logger.info("reopen: ignored a malformed request")
            return false
        }
        guard let sender, isConfiguredViewer(sender, settings: settings) else {
            logger.info("reopen: refused a request from an app that is not a configured external viewer")
            return false
        }
        if let state = AppState.activeInstances.allObjects.first(where: {
            $0.librarySettings?.libraryUUID?.lowercased() == request.libraryUUID
        }) {
            state.handleViewerReopen(request, sender: sender)
            return true
        }
        // 覚えている場所はパスの形だけを確かめる（存在の確かめはしない ―― ネットワークの上のライブラリでメインを止めない。無ければ
        // ライブラリを開く道がいつもどおり知らせる）。
        guard let bundlePath = ViewerReopenLibraries.shared.bundlePath(for: request.libraryUUID),
              (bundlePath as NSString).pathExtension.lowercased() == "stacknest"
        else {
            // 外部ビューアからの頼みなので知らせる。`application(_:open:)` の中（起動の途中もある）で止めないよう、次の周回で。
            DispatchQueue.main.async {
                presentAlert(String(localized: "外部ビューアから頼まれた本のライブラリが見つかりません。StackNest でライブラリを開いてから、もう一度開いてください。"))
            }
            return false
        }
        // ライブラリを開き、読み終えたところで渡す（AppState が `take(bundlePath:)` で受け取る）。
        prunePending()
        pending.append(Pending(bundlePath: bundlePath, request: request, sender: sender, receivedAt: Date()))
        URLOpener.shared.enqueue(URL(fileURLWithPath: bundlePath))
        return true
    }

    /// 送り手が、設定にある外部ビューア（既定・種類ごと・EPUB のどれか）で、読書位置の同期（参照ファイルで渡す）が ON か。
    /// アプリの場所は記号リンクを解いて比べる。
    static func isConfiguredViewer(_ sender: URL, settings: ViewerSettings) -> Bool {
        guard settings.syncsReadingPositionWithExternalViewer else { return false }
        let paths = [settings.externalViewerAppPath, settings.epubViewerAppPath].compactMap { $0 }
            + Array(settings.categoryViewerPaths.values)
        let target = canonicalAppPath(sender)
        return paths.contains { canonicalAppPath(URL(fileURLWithPath: $0)) == target }
    }

    /// アプリの場所の比べ方（記号リンクを解いて揃える）。送り手と、渡す外部ビューアの比べ方を 1 つにする。
    static func canonicalAppPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// 開き終えたライブラリの窓が、自分宛ての頼みを受け取る（届いた順に全部。期限の過ぎたものは捨てる）。
    static func take(bundlePath: String) -> [(request: StackNestReopenRequest, sender: URL)] {
        prunePending()
        let mine = pending.filter { $0.bundlePath == bundlePath }
        pending.removeAll { $0.bundlePath == bundlePath }
        return mine.map { ($0.request, $0.sender) }
    }

    /// ライブラリを開くのを待っている頼み。ライブラリを開けなかった（壊れている・キャンセルした）ときに残らないよう、
    /// `pendingLifetime` を過ぎたものは捨てる（以前は 1 件だけを持ち、開けなかったら消えずに残って、何日も後に手で開いたときに
    /// 本が渡っていた ―― 2 回目のレビュー M-B）。
    private struct Pending {
        let bundlePath: String
        let request: StackNestReopenRequest
        let sender: URL
        let receivedAt: Date
    }
    private static var pending: [Pending] = []
    static let pendingLifetime: TimeInterval = 120

    private static func prunePending(now: Date = Date()) {
        pending.removeAll { now.timeIntervalSince($0.receivedAt) > pendingLifetime }
    }

    /// 頼みの Apple Event の送り手のアプリ（`application(_:open:)` の中で呼ぶ。分からなければ nil）。
    static func senderOfCurrentEvent() -> URL? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              pid > 0,
              let app = NSRunningApplication(processIdentifier: pid_t(pid))
        else { return nil }
        return app.bundleURL
    }

    static func presentAlert(_ text: String) {
        // 外部ビューアは StackNest を前に出さずに頼むので、知らせるときは前に出る。
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "外部ビューアの本を開けません")
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// 外部ビューアへ本を渡したことのあるライブラリの場所（UUID → パッケージのパス）。外部ビューアが閉じたライブラリの本を
/// 頼んだとき（`ViewerReopen`）に開くため。渡すたびに覚え直す（ライブラリを動かしても、次に渡したときに追いつく）。
/// 新しい順に `maxCount` 件まで。
@MainActor
final class ViewerReopenLibraries {
    static let shared = ViewerReopenLibraries(defaults: .standard)
    static let defaultsKey = "viewerReopenLibraryPaths"
    static let maxCount = 64

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 覚えている場所（UUID は小文字にそろえて引く）。
    func bundlePath(for libraryUUID: String) -> String? {
        entries().first { $0.uuid == libraryUUID.lowercased() }?.path
    }

    /// 本を渡したライブラリの場所を覚える（いちばん新しくする）。
    func record(libraryUUID: String, bundlePath: String) {
        let uuid = libraryUUID.lowercased()
        var list = entries().filter { $0.uuid != uuid && $0.path != bundlePath }
        list.insert((uuid, bundlePath), at: 0)
        defaults.set(list.prefix(Self.maxCount).map { ["uuid": $0.uuid, "path": $0.path] }, forKey: Self.defaultsKey)
    }

    private func entries() -> [(uuid: String, path: String)] {
        (defaults.array(forKey: Self.defaultsKey) as? [[String: String]] ?? []).compactMap { item in
            guard let uuid = item["uuid"], let path = item["path"] else { return nil }
            return (uuid, path)
        }
    }
}

extension AppState {
    /// 外部ビューアからの頼みでこのライブラリの本を渡す（`ViewerReopen`）。施錠していて未解錠なら、解錠に成功したときに
    /// 渡す（`consumePendingViewerReopen`）。
    func handleViewerReopen(_ request: StackNestReopenRequest, sender: URL) {
        if needsUnlock {
            pendingViewerReopen.append((request, sender))
            // 外部ビューアは StackNest を前に出さずに頼む(形式の文書の勧め)ので、解錠の画面が要るときは自分で前に出る。
            // ライブラリの窓を前に出すのは、⌘⇧O の続きから開く道と同じく、その窓の値で開き直す(SwiftUI は同じ値の窓を前へ出す)。
            // (App のテストのホストでは窓を出さない ―― AppEnvironment.isRunningUnitTests。)
            if !AppEnvironment.isRunningUnitTests {
                NSApp.activate()
                URLOpener.shared.enqueue(bundleURL)
            }
            return
        }
        guard let book = try? database?.fetchBook(id: request.bookID),
              let uuid = librarySettings?.libraryUUID,
              ViewerBookIdentity.value(libraryUUID: uuid, bookID: book.id, dateAdded: book.dateAdded)
                  == request.bookIdentity
        else {
            watchNotice.present(Notice(kind: .warning, text: String(localized: "外部ビューアから頼まれた本は、このライブラリにありません。")))
            return
        }
        // 頼んだアプリが、今この本を渡す外部ビューアであるときだけ渡す（ほかのアプリの頼みで、設定していないアプリへ渡さない）。
        guard let viewer = referenceViewerForReopen(book),
              ViewerReopen.canonicalAppPath(viewer.appURL) == ViewerReopen.canonicalAppPath(sender)
        else {
            ViewerReopen.logger.info("reopen: the sender is not the external viewer for this book")
            watchNotice.present(Notice(kind: .warning, text: String(localized: "頼んだアプリは、この本を渡す外部ビューアではないため、渡しませんでした。")))
            return
        }
        // 窓で選んで開いたときと同じく、「最後に開いた本」とライブラリの場所を覚え直す（ライブラリを動かしていても追いつく）。
        viewerHandoff.recordLastRead(.local(bundlePath: bundleURL.path, bookID: book.id, title: book.title))
        if let uuid = librarySettings?.libraryUUID { viewerHandoff.recordLibraryForReopen(uuid, bundleURL.path) }
        Task { @MainActor in await self.openInExternalViewerSyncing([book]) }
    }

    /// 解錠に成功したときに、待たせていた頼みを渡す（届いた順に、1 回だけ）。
    func consumePendingViewerReopen() {
        guard isUnlocked, !pendingViewerReopen.isEmpty else { return }
        let pending = pendingViewerReopen
        pendingViewerReopen = []
        for item in pending { handleViewerReopen(item.request, sender: item.sender) }
    }
}
