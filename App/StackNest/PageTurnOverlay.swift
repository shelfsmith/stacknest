// SPDX-License-Identifier: MIT
import AppKit
import AppCore

/// G54-S3: ページ送りの演出の部品。窓は protocol 越しに使い、テストで差し替える。
@MainActor
protocol PageTurnAnimating: AnyObject {
    /// 旧ページを撮って、`view` の直上に被せる。撮れなければ false（演出なしで進める）。
    func capture(from view: NSView) -> Bool
    /// 被せた画像を plan に従って動かして外す。capture していなければ何もしない。
    func run(_ plan: PageTurnPlan)
    /// 被せた画像をすぐ外す（演出中でも）。
    func cancel()
}

/// G54-S3 fix round 1: 被せ物専用の NSView。既定の `hitTest` は自分自身を返すため、被せている間
/// マウスクリック・スクロール・ピンチが `ViewerCanvasView` ではなくこの被せ物に届いてしまい、
/// 0.25 秒間隔のクリック送りを取りこぼす（`PassthroughHostingView` と同じ回避）。`nil` を返して
/// ヒットテストを素通りさせる — 被せ物は見た目だけで、入力には無関係。
private final class PageTurnCoverView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// G54-S3: Washi と同じ方式の演出。送る直前のキャンバスを画像として撮って被せ、新ページを描いた直後に
/// その被せ物をスライドで抜く（またはフェードで消す）。キャンバスの描画（ズーム・パン・ルーペ）には触れない。
@MainActor
final class PageTurnOverlay: PageTurnAnimating {
    private var cover: NSView?

    func capture(from view: NSView) -> Bool {
        cancel()
        guard let parent = view.superview, view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return false }
        let cover = PageTurnCoverView(frame: view.frame)
        cover.wantsLayer = true
        // キャンバスの黒背景は layer の属性で `cacheDisplay` に写らないので、被せ物の側で塗る。
        cover.layer?.backgroundColor = NSColor.black.cgColor
        cover.layer?.contents = image
        cover.layer?.contentsGravity = .resize
        // G54-S3 fix round 1 (Minor A): 被せている間にウィンドウがリサイズ/フルスクリーン化されても
        // キャンバスと同じ矩形を保つ（さもないと被せ物だけ旧サイズのまま残りズレる）。
        cover.autoresizingMask = [.width, .height]
        parent.addSubview(cover, positioned: .above, relativeTo: view)
        self.cover = cover
        return true
    }

    func run(_ plan: PageTurnPlan) {
        guard let cover else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PageTurnDecision.duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            switch plan.style {
            case .slide:
                let dx = (plan.slideTowardRight ? 1 : -1) * cover.frame.width
                cover.animator().frame = cover.frame.offsetBy(dx: dx, dy: 0)
            case .fade, .off:
                cover.animator().alphaValue = 0
            }
        }
        // 完了ハンドラは Sendable 境界で NSView を渡せないため、同じ長さだけ待ってから外す。
        // 待つ間に cancel / 次の capture が来ていれば、その被せ物は既に外れている（removeFromSuperview は無害）。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(PageTurnDecision.duration + 0.05))
            cover.removeFromSuperview()
            if self?.cover === cover { self?.cover = nil }
        }
    }

    func cancel() {
        cover?.removeFromSuperview()
        cover = nil
    }
}
