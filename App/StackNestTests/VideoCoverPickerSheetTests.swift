// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Testing
@testable import StackNest

/// G50 smoke（2026-09-08・M4 実機）: 表紙の右クリック →「動画からシーンを選ぶ…」でアプリが落ちた。
/// クラッシュログ: `NSViewRepresentable._makeView` → `ViewResponderFilter.init` →
/// `swift_getAssociatedTypeWitnessSlow` → `_AVKit_SwiftUI` の
/// `__swift_instantiateGenericMetadata` → `getSuperclassMetadata` で
/// **Swift ランタイムの fatalError（abort）**。
///
/// `VideoCoverPickerSheet` は SwiftUI の `VideoPlayer`（`_AVKit_SwiftUI`）を使う。
/// その内部の generic クラスは **AVKit の ObjC クラスを継承**しているため、
/// `AVKit.framework` がプロセスに読み込まれていないと superclass のメタデータを解決できない。
/// アプリは `AVFoundation` と `_AVKit_SwiftUI` はリンクしていたが、**`AVKit` はリンクしていなかった**
/// （`otool -L` で確認）。Swift の autolink は `VideoPlayer` が struct で AVKit のシンボルを
/// 直接참照しないため、AVKit を引き込まなかった。
///
/// このテストは実際にシートを `NSHostingView` に載せてレイアウトさせる。
/// メタデータ生成に失敗すればテストプロセスごと abort する（＝失敗として見える）。
@MainActor
@Suite("G50: 動画シーン選択シートが生成できる")
struct VideoCoverPickerSheetTests {

    @Test("シートを NSHostingView に載せてもクラッシュしない（AVKit のメタデータ解決）")
    func sheetBuildsWithoutCrashing() throws {
        let url = URL(fileURLWithPath: "/dev/null")   // 再生はしない。生成できるかだけを見る
        let sheet = VideoCoverPickerSheet(url: url, onPicked: { _, _ in }, onCancel: {})
        let host = NSHostingView(rootView: sheet)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        // ここでビュー木が構築される。AVKit が解決できなければ abort する。
        host.layoutSubtreeIfNeeded()
        #expect(host.subviews.isEmpty == false)
    }
}
