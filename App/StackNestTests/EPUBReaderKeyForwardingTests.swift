// SPDX-License-Identifier: MIT
import Testing
import AppKit
import WebKit
import EPUBAdapter
import WashiEPUBAdapter
@testable import StackNest

/// G48-4 smoke（2026-09-06）: Washi の窓で `-`・Esc・`+`（⌘なし）を押すとアプリが落ちた。
/// クラッシュログ: `EPUBReaderView.keyDown` → `WKWebView.keyDown` → `_web_superKeyDown`
/// → nextResponder（= `EPUBReaderView`）→ `keyDown` … の無限再帰でスタックオーバーフロー。
/// 上流 1.16.0（cooViewer-oxr.80）が追加した `EPUBReaderView.keyDown` は
/// `handlesKeyboardNavigation == true` のとき受け取ったキーを自分の WebView へ転送するが、
/// WebView が扱わないキーは `super` から nextResponder（コンテナ自身）へ戻るため往復する。
///
/// このテストは実際の `EPUBReaderView` を窓に載せ、WebView を first responder にして
/// 「WebView が扱わないキー」を送る。再帰があればテストプロセスごと落ちる（＝失敗）。
///
/// **注意（2026-09-06）**: 修正前のビルドでもこのテストは落ちなかった（テストホストでは WebKit の
/// 「未処理キーの `_web_superKeyDown` 折り返し」が実機と同じ経路を通らない模様。原因は未特定）。
/// したがって本テストは再現テストではなく、キー経路が例外なく通ることの煙テストとして残す。
/// 実機での再確認（`-`・Esc・`+`）が修正の検証になる。
@MainActor
@Suite("G48-4: WebView が扱わないキーで EPUBReaderView が再帰しない")
struct EPUBReaderKeyForwardingTests {

    /// 最小のテキスト EPUB を `/usr/bin/zip` で作る（EPUBAdapterTestSupport を App テストに足さないため）。
    private func makeMinimalEPUB() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("g48-4-key-\(UUID().uuidString)")
        let work = dir.appendingPathComponent("src")
        let fm = FileManager.default
        try fm.createDirectory(at: work.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: work.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.write(to: work.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:g48-4-key</dc:identifier><dc:title>key</dc:title><dc:language>ja</dc:language></metadata><manifest><item id="p1" href="p1.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine page-progression-direction="rtl"><itemref idref="p1"/></spine></package>
        """.write(to: work.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>p1</title></head><body><p>本文</p></body></html>
        """.write(to: work.appendingPathComponent("OEBPS/p1.xhtml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>nav</title></head><body><nav epub:type="toc"><ol><li><a href="p1.xhtml">p1</a></li></ol></nav></body></html>
        """.write(to: work.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)
        let out = dir.appendingPathComponent("key.epub")
        try run("/usr/bin/zip", ["-X", "-0", out.path, "mimetype"], cwd: work)
        try run("/usr/bin/zip", ["-X", "-r", "-9", "-D", out.path, "META-INF", "OEBPS"], cwd: work)
        return out
    }

    private func run(_ exe: String, _ args: [String], cwd: URL) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.currentDirectoryURL = cwd; p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "zip", code: Int(p.terminationStatus)) }
    }

    /// 表示用の WebView だけを返す（Washi 1.16 は census 用の不可視 WebView も持つ）。
    private func findWebView(in view: NSView) -> WKWebView? {
        allWebViews(in: view).first { !$0.isHidden && $0.frame.width > 0 && ($0.superview?.className ?? "").hasSuffix("EPUBReaderView") }   // 番人のため Washi は import しない
    }
    private func allWebViews(in view: NSView) -> [WKWebView] {
        var out: [WKWebView] = []
        if let wv = view as? WKWebView { out.append(wv) }
        for sub in view.subviews { out += allWebViews(in: sub) }
        return out
    }

    private func keyEvent(_ chars: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    }

    @Test("`-`・Esc・`+` を WebView に送っても落ちない（上流 1.16.0 の keyDown 往復）")
    func unhandledKeysDoNotRecurse() async throws {
        let url = try makeMinimalEPUB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reader = try await WashiEPUBRenderer().makeReaderView(url: url, at: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = reader.view
        window.orderFrontRegardless()
        // load は窓に載って実寸が決まってから走る（G48-2）。WebView が現れるまで待つ。
        var webView: WKWebView? = nil
        for _ in 0..<80 {   // 最大 8 秒
            if let wv = findWebView(in: reader.view) { webView = wv; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let wv = try #require(webView, "WKWebView が現れない（load が走っていない）")
        try await Task.sleep(for: .seconds(1))   // 先頭文書の読み込みを待つ
        let all = allWebViews(in: reader.view)
        print("[keytest] webviews=\(all.count) chosen superview=\(type(of: wv.superview as Any)) hidden=\(wv.isHidden) frame=\(wv.frame) nextResponder=\(type(of: wv.nextResponder as Any))")
        window.makeFirstResponder(wv)
        print("[keytest] firstResponder=\(type(of: window.firstResponder as Any))")

        // WebView が扱わないキー。修正前はここで無限再帰 → テストプロセスごと落ちる。
        for (chars, code, flags) in [("-", UInt16(27), NSEvent.ModifierFlags()),
                                     ("\u{1B}", UInt16(53), NSEvent.ModifierFlags()),
                                     ("+", UInt16(41), NSEvent.ModifierFlags.shift)] {
            let ev = keyEvent(chars, keyCode: code, flags: flags, window: window)
            window.sendEvent(ev)   // 実機と同じ経路（firstResponder の keyDown → WebKit → super → nextResponder）
            try await Task.sleep(for: .milliseconds(400))
        }
        #expect(findWebView(in: reader.view) != nil)   // ここまで到達すれば再帰していない
        window.orderOut(nil)
    }
}
