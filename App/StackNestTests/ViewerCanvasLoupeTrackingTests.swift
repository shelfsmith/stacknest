// SPDX-License-Identifier: MIT
import Testing
import AppKit
@testable import StackNest

/// G38 実機 smoke: ルーペ ON でクリックしてページを送ると、円が消えてカーソルを動かすまで戻らなかった
/// （キーボードでのページ送りでは起きない＝マウスイベント経路の問題）。
///
/// `loupeCursor` に nil を入れる箇所はコード中 `mouseExited` の 1 箇所だけで、`loupeEnabled` は
/// 真のまま（動かせば復帰した＝`mouseMoved` の guard を通っている）。つまり**ポインタが中にあるのに
/// `mouseExited` が来ていた**。原因は `updateTrackingAreas()` が毎回領域を貼り直していたこと ——
/// 領域を外した瞬間に AppKit が「古い領域から出た」として退出を送る。
@Suite("ルーペのトラッキング領域と偽の退出（G38 smoke）")
struct ViewerCanvasLoupeTrackingTests {
    @MainActor
    private func makeCanvas() -> ViewerCanvasView {
        ViewerCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    /// 何度呼ばれても領域は 1 つのまま。貼り直しが起きないことが、偽の退出が出ない条件。
    @MainActor
    @Test func updateTrackingAreasDoesNotRebuildTheArea() {
        let canvas = makeCanvas()
        canvas.updateTrackingAreas()
        let first = canvas.trackingAreas
        #expect(first.count == 1, "ルーペ用の領域は 1 つだけ付く")

        for _ in 0..<5 { canvas.updateTrackingAreas() }
        #expect(canvas.trackingAreas.count == 1, "呼ぶたびに領域が増えてはいけない")
        #expect(canvas.trackingAreas.first === first.first,
                "同じ領域を使い回すこと。貼り直すと AppKit が偽の mouseExited を送る")
    }

    /// 領域が何らかの理由で外された場合は、貼り直して機能を保つ（使い回しは手抜きではない）。
    @MainActor
    @Test func updateTrackingAreasRestoresARemovedArea() {
        let canvas = makeCanvas()
        canvas.updateTrackingAreas()
        canvas.trackingAreas.forEach(canvas.removeTrackingArea)
        #expect(canvas.trackingAreas.isEmpty)

        canvas.updateTrackingAreas()
        #expect(canvas.trackingAreas.count == 1, "外れていたら貼り直さなければならない")
    }

    /// 退出の真偽判定。ポインタが bounds の中にあるうちは、退出を信じてはいけない。
    @MainActor
    @Test func exitIsRealOnlyWhenThePointerIsActuallyOutside() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

        #expect(ViewerCanvasView.isRealExit(pointerInView: CGPoint(x: 400, y: 300), bounds: bounds) == false,
                "ど真ん中にポインタがあるのに退出を信じると、クリックのたびにルーペが消える")
        #expect(ViewerCanvasView.isRealExit(pointerInView: CGPoint(x: 0, y: 0), bounds: bounds) == false,
                "左下角は bounds の内側")

        #expect(ViewerCanvasView.isRealExit(pointerInView: CGPoint(x: -1, y: 300), bounds: bounds),
                "左端の外は本物の退出")
        #expect(ViewerCanvasView.isRealExit(pointerInView: CGPoint(x: 800, y: 300), bounds: bounds),
                "右端は bounds.contains が false（maxX は含まれない）＝本物の退出")
        #expect(ViewerCanvasView.isRealExit(pointerInView: CGPoint(x: 400, y: 601), bounds: bounds),
                "上端の外は本物の退出")

        #expect(ViewerCanvasView.isRealExit(pointerInView: nil, bounds: bounds),
                "ウィンドウが無く裏が取れないときは、素直に本物として扱う")
    }
}
