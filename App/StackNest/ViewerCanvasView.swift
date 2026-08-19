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
///
/// G18 C2: 表示する画像は `NSImage`（lazy decode）ではなく、呼び出し側（ViewerWindowController）が
/// off-main で即時デコード済みの `DecodedImage`（CGImage）を渡す。draw(_:) は `NSImage.draw(in:)`
/// ではなく CGContext への直接 blit（`context.draw(cgImage, in:)`）を使うため、このビューの
/// draw(_:) 内でピクセルデコードが走ることは一切ない（デコード済み CGImage を貼るだけ）。
@MainActor
final class ViewerCanvasView: NSView {
    private var images: [DecodedImage] = []      // 0〜2 枚（見開き）
    private let gutter: CGFloat = 0          // 見開き中央のガター幅（px）
    /// pages[0] を右に置くか（RTL=true）。spreadDrawRects の並び順に使う。
    var firstOnRight: Bool = true
    private var zoomFactor: CGFloat = 1.0   // 1.0 = フィット, >1 = ズームイン
    private var offset: CGSize = .zero
    private let maxZoomFactor: CGFloat = 8.0

    /// G38: ルーペの ON/OFF。`ViewerWindowController` から設定される。
    var loupeEnabled: Bool = false {
        didSet {
            // G38 review I-2: loupeCursor は mouseMoved でしか入らないため、ON にした瞬間にマウスが
            // 静止していると円が一切描かれない（「押したのに無反応」に見える）。ON になった時点で
            // 現在のカーソル位置を能動的に取得して補う。ウィンドウ外なら nil のままで構わない。
            if loupeEnabled, let window {
                loupeCursor = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            }
            needsDisplay = true
        }
    }
    /// 最後に観測したカーソル位置（View 座標）。ウィンドウ外なら nil。
    private var loupeCursor: CGPoint?
    /// G38 §5: 倍率は固定。**可変化フェーズで触るのはこの 1 箇所だけ**にするため、
    /// 再デコードの判定にも `2.0` を直接書かずこの定数を使う。
    static let loupeMagnification: CGFloat = 2.0
    private let loupeDiameter: CGFloat = 300

    /// 実効スケール。常に現在の fitScale から導出するため、zoomFactor==1 のとき
    /// ウィンドウ拡大/縮小の両方向でフィットが追従する（絶対 scale 保持による
    /// "縮小時に user-zoomed と誤判定" を根治。smoke v3 KEEP-ZOOM 誤分類の修正）。
    private var scale: CGFloat { fitScale * zoomFactor }

    private var mouseDownLocation: NSPoint?
    private var didDrag = false

    /// 左右ゾーン単クリック送り。leftHalf=true なら画面左半分クリック。controller が方向解釈。
    var onZoneClick: ((_ leftHalf: Bool) -> Void)?

    /// G18 C4: ズーム操作（±キー/ピンチ＝ `applyZoom` 経由）で `zoomFactor` が実際に変わるたびに
    /// 呼ばれる。パン（`scrollWheel`/`mouseDragged`）や、ページ送りのたびに `setImages` が呼ぶ
    /// `fitToWindow()` のリセットからは呼ばれない — controller はこれを「ユーザーが今まさに
    /// ズーム操作をした」シグナルとして扱い、デバウンス後に高解像再デコードの要否を判定する。
    var onZoomChanged: ((CGFloat) -> Void)?

    /// G18 C4: 現在の zoom 倍率（1.0 = フィット）。controller がズーム再デコードの target 計算
    /// （`DecodeTargetMath.zoomDecodeTarget`）に使う。読み取り専用。
    var currentZoomFactor: CGFloat { zoomFactor }

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
    /// 渡す `DecodedImage` は呼び出し側で既に off-main デコード済み（G18 C2）。
    func setImages(_ images: [DecodedImage]) {
        self.images = images
        fitToWindow()
    }

    /// G18 C4: ズーム再デコードで高解像度の `DecodedImage` に差し替える。`setImages` と異なり、
    /// 現在の `zoomFactor`/`offset`（ユーザーがまさに操作しているズーム位置）を維持したまま
    /// 画像だけ差し替える（フィットへリセットしない）。ソフト→鮮明の一瞬の差し替えなので、
    /// ユーザーのズーム/パン位置を壊してはならない。差し替え後の画像サイズ変化（僅かな
    /// アスペクト丸め差）に備え、offset だけ再クランプする。
    func swapImagesPreservingZoom(_ images: [DecodedImage]) {
        self.images = images
        clampOffsetForCurrentScale()
        refresh()
    }

    /// 各画像のサイズ（描画と幾何計算に使う）。DecodedImage.pixelSize はデコード時に確定済みの
    /// 実ピクセルサイズ（EXIF 回転適用後）で、CGImage.width/height と一致する。
    /// 見開きの facing ページを同じ表示高さに揃えるため、共通高さへ正規化する（アスペクト比は各画像で保存）。
    /// これが無いと単一 scale がネイティブ px に乗算され、同一アスペクトでも解像度違いのページ
    /// （例: 1131x1608 と 1351x1920 が同一巻に混在する漫画）で低解像度側が小さく描画される。
    /// n=1・均一サイズでは素通し（従来と同一）。native 画像は同一アスペクトの矩形へ描くので歪まない。
    private var imageSizes: [CGSize] { CanvasFitMath.heightNormalized(images.map { $0.pixelSize }) }

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
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rects = CanvasFitMath.spreadDrawRects(
            images: imageSizes,
            viewSize: bounds.size,
            scale: scale,
            offset: offset,
            gutter: gutter,
            firstOnRight: firstOnRight
        )
        ctx.interpolationQuality = .high
        // G18 C2: NSImage.draw(in:) から CGContext blit へ移行。座標系メモ:
        // このビューは `isFlipped == false`（Quartz ネイティブ: 原点左下・y 上向き）。
        // CGContext.draw(_:in:) はこの向きの（非flipped）コンテキストへ描くと CGImage を
        // 追加の反転操作なしで正しい向き（天地逆転なし）で描画する。これは
        // `NSImage.draw(in:...respectFlipped:true...)` が旧実装で行っていた自動補正と
        // 結果的に同じ見た目になる（respectFlipped は isFlipped==true のビュー向けの
        // 補正であり、false のこのビューでは元々ほぼ no-op だった）。
        // 実機検証のみに頼らず、CGBitmapContext を使った独立スクリプトで
        // 「非flippedコンテキストへの直接 draw で天地が保たれる」ことをオフラインで実証済み
        // （G18 C2 実装時）。もし将来 isFlipped を true に変更する場合は、ここで
        // `ctx.translateBy(x: 0, y: rect.maxY + rect.minY); ctx.scaleBy(x: 1, y: -1)` 相当の
        // 反転を追加すること。
        for (i, decoded) in images.enumerated() where i < rects.count {
            let rect = rects[i]
            guard rect.width > 0, rect.height > 0 else { continue }
            ctx.draw(decoded.cgImage, in: rect)
        }

        // G38: ルーペ。既存の描画の上に円を 1 つ重ねるだけ。
        guard loupeEnabled, let cursor = loupeCursor else { return }
        let sources = CanvasFitMath.loupeSource(
            images: imageSizes, nativeSizes: images.map { $0.pixelSize },
            viewSize: bounds.size, scale: scale, offset: offset,
            gutter: gutter, firstOnRight: firstOnRight,
            cursor: cursor, loupeDiameter: loupeDiameter,
            magnification: Self.loupeMagnification)
        // G38 review I-4: sources が空（カーソルが黒余白の上）でも黒塗り＋縁は描く。spec §3 の
        // 「画像の外（余白）にかかった部分は背景色になる」を満たすには円自体が消えてはいけない
        // （以前は guard で早期 return し、円ごと消えていた）。中身が無ければ下の for ループが
        // 単に何も描かないだけで安全。

        let circle = CGRect(x: cursor.x - loupeDiameter / 2, y: cursor.y - loupeDiameter / 2,
                            width: loupeDiameter, height: loupeDiameter)
        ctx.saveGState()
        ctx.addEllipse(in: circle)
        ctx.clip()
        NSColor.black.setFill()
        ctx.fill(circle)
        for s in sources where s.imageIndex < images.count {
            if let cropped = images[s.imageIndex].cgImage.cropping(to: s.sourceRect) {
                ctx.draw(cropped, in: s.destRect)
            }
        }
        ctx.restoreGState()
        // 縁を描く。ON であることがこれで分かる（spec §4）。
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: circle)
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
        onZoomChanged?(zoomFactor)
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
        // G38 review I-3: ドラッグ中は mouseMoved が来ないため、ズーム中のパン操作をしている間だけ
        // ルーペの円がカーソルから取り残される。純追加でここにも追従させる（既存行は 1 行も変更しない）。
        if loupeEnabled {
            loupeCursor = convert(event.locationInWindow, from: nil)
        }
    }

    /// clickCount は見ない（D13: 同一位置の2回目クリックが double-click 扱いで無反応になる不具合の根治）。
    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard !didDrag else { return }
        let p = convert(event.locationInWindow, from: nil)
        onZoneClick?(p.x < bounds.midX)
    }

    // MARK: - Loupe (G38)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard loupeEnabled else { return }
        loupeCursor = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        loupeCursor = nil
        needsDisplay = true
    }
}
