// SPDX-License-Identifier: MIT
import AppKit
import AppCore

/// 1 ページ画像を表示する自前描画キャンバス（NSScrollView 非依存）。
/// フィット（既定・= キー）・ズーム（ピンチ/＋−）・パン（ズーム中はドラッグ&スクロール）・左右ゾーン送り。
/// 幾何計算は AppCore の `CanvasFitMath`（ユニットテスト済）に委譲する。
///
/// 画像は子 `NSImageView` ではなく **自前で `draw(_:)` 描画** する。子 NSImageView を載せると
/// それが hitTest 先になり `magnify(with:)`/`scrollWheel(with:)` を握り潰してしまい（mouseDown/Up は
/// responder chain を遡るがジェスチャ/スクロールは hitTest ビューで止まる）、ピンチズーム・スクロール
/// パンが一切届かなくなる（smoke v2 NG の根因）。自前描画ならこのビュー自身が hitTest 先になり、
/// 全イベントを確実に受け取れる。
@MainActor
final class ViewerCanvasView: NSView {
    private var images: [NSImage] = []      // 0〜2 枚（見開き）
    private let gutter: CGFloat = 0          // 見開き中央のガター幅（px）
    /// pages[0] を右に置くか（RTL=true）。spreadDrawRects の並び順に使う。
    var firstOnRight: Bool = true
    private var zoomFactor: CGFloat = 1.0   // 1.0 = フィット, >1 = ズームイン
    private var offset: CGSize = .zero
    private let maxZoomFactor: CGFloat = 8.0

    /// 実効スケール。常に現在の fitScale から導出するため、zoomFactor==1 のとき
    /// ウィンドウ拡大/縮小の両方向でフィットが追従する（絶対 scale 保持による
    /// "縮小時に user-zoomed と誤判定" を根治。smoke v3 KEEP-ZOOM 誤分類の修正）。
    private var scale: CGFloat { fitScale * zoomFactor }

    private var mouseDownLocation: NSPoint?
    private var didDrag = false

    /// 左右ゾーン単クリック送り。leftHalf=true なら画面左半分クリック。controller が方向解釈。
    var onZoneClick: ((_ leftHalf: Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override var isFlipped: Bool { false }

    /// 1〜2 枚を設定する（0 枚=何も描かない）。設定するたびフィットへ戻す。
    func setImages(_ images: [NSImage]) {
        self.images = images
        fitToWindow()
    }

    /// 各画像のサイズ（描画と幾何計算に使う）。
    /// 見開きの facing ページを同じ表示高さに揃えるため、共通高さへ正規化する（アスペクト比は各画像で保存）。
    /// これが無いと単一 scale がネイティブ px に乗算され、同一アスペクトでも解像度違いのページ
    /// （例: 1131x1608 と 1351x1920 が同一巻に混在する漫画）で低解像度側が小さく描画される。
    /// n=1・均一サイズでは素通し（従来と同一）。native 画像は同一アスペクトの矩形へ描くので歪まない。
    private var imageSizes: [CGSize] { CanvasFitMath.heightNormalized(images.map { $0.size }) }

    /// 見開き全体の合計サイズ（scale=1 基準）。クランプ計算に使う。
    /// 横 = Σ幅 + ガター*(n-1)、縦 = 最大高。
    private var combinedSize: CGSize {
        guard !images.isEmpty else { return .zero }
        let totalW = imageSizes.reduce(0) { $0 + $1.width } + gutter * CGFloat(max(0, images.count - 1))
        let maxH = imageSizes.reduce(0) { max($0, $1.height) }
        return CGSize(width: totalW, height: maxH)
    }

    private var fitScale: CGFloat {
        CanvasFitMath.spreadFitScale(images: imageSizes, viewSize: bounds.size, gutter: gutter)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.setFill()
        dirtyRect.fill()
        guard !images.isEmpty else { return }
        let rects = CanvasFitMath.spreadDrawRects(
            images: imageSizes,
            viewSize: bounds.size,
            scale: scale,
            offset: offset,
            gutter: gutter,
            firstOnRight: firstOnRight
        )
        for (i, image) in images.enumerated() where i < rects.count {
            let rect = rects[i]
            guard rect.width > 0, rect.height > 0 else { continue }
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }

    /// scale/offset を変えたら再描画を要求する（フレーム juggling 不要）。
    private func refresh() { needsDisplay = true }

    // MARK: - Fit / Resize

    /// フィット（= キー）: zoomFactor=1, offset=0。
    func fitToWindow() {
        zoomFactor = 1.0
        offset = .zero
        refresh()
    }

    /// リサイズ時: scale は常に現在の fitScale から導出されるので scale-vs-fit の分岐は不要。
    /// zoomFactor==1 ならフィットが両方向で追従し、>1 ならズーム倍率がそのまま維持される。
    func handleResize() {
        clampOffsetForCurrentScale()
        refresh()
    }

    /// 自身のサイズ変更を捕捉する確実な hook。制約・autoresizing・手動いずれの経路でも呼ばれ、
    /// `super` 適用後は `bounds` が新サイズに更新済みなので fitScale を正しく再計算できる。
    /// （windowDidResize 通知は canvas の bounds 更新前に届くことがあり stale を読むため、ここで根治する。）
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        handleResize()
    }

    private func clampOffsetForCurrentScale() {
        let widthSum = imageSizes.reduce(0) { $0 + $1.width }
        let gutters = gutter * CGFloat(max(0, images.count - 1))
        let scaledW = widthSum * scale + gutters          // gutter NOT scaled — matches spreadDrawRects
        let scaledH = combinedSize.height * scale          // height has no gutter, scaling is correct
        offset = CanvasFitMath.clampOffset(offset, scaledImageSize: CGSize(width: scaledW, height: scaledH), viewSize: bounds.size)
    }

    // MARK: - Zoom

    func zoomIn()  { applyZoom(zoomFactor * 1.25) }
    func zoomOut() { applyZoom(zoomFactor / 1.25) }

    private func applyZoom(_ newFactor: CGFloat) {
        zoomFactor = min(max(newFactor, 1.0), maxZoomFactor)
        if zoomFactor <= 1.0 { offset = .zero }
        clampOffsetForCurrentScale()
        refresh()
    }

    override func magnify(with event: NSEvent) {
        applyZoom(zoomFactor * (1 + event.magnification))
    }

    private var isZoomed: Bool { zoomFactor > 1.0001 }

    // MARK: - Pan

    override func scrollWheel(with event: NSEvent) {
        guard isZoomed else { return }
        offset.width  += event.scrollingDeltaX
        offset.height -= event.scrollingDeltaY
        clampOffsetForCurrentScale()
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        if let down = mouseDownLocation {
            let dx = event.locationInWindow.x - down.x
            let dy = event.locationInWindow.y - down.y
            if (dx * dx + dy * dy) > 25 { didDrag = true }
        }
        guard isZoomed else { return }
        offset.width  += event.deltaX
        offset.height -= event.deltaY
        clampOffsetForCurrentScale()
        refresh()
    }

    /// clickCount は見ない（D13: 同一位置の2回目クリックが double-click 扱いで無反応になる不具合の根治）。
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard !didDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        onZoneClick?(p.x < bounds.midX)
    }
}
