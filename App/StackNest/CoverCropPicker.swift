// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore  // AspectFitter

/// Phase 2.5h A18-ext: 横長カバー画像上の crop 矩形を指定する UI。
/// 親 sheet が画像 + 「crop 矩形を指定」ボタンを表示し、本 view は矩形だけを担当する。
/// 矩形は正規化座標 (0.0-1.0) で表現される。
/// コーナー リサイズは YAGNI — 親 sheet 側で幅・高さ Slider を提供することで代替する。
struct CoverCropPicker: View {
    let image: NSImage
    @Binding var normalizedRect: CGRect  // {x, y, w, h} all in 0.0-1.0

    @State private var dragOrigin: CGRect = CGRect(x: 0.25, y: 0, width: 0.5, height: 1.0)
    // Phase 2.5g+h+i fixup v2: drag 中フラグ。
    // .onChange(of: normalizedRect) が drag 経由の更新で発火し dragOrigin を
    // 累積上書きすると、translation 計算の基準点が動いて指数加速バグになる
    // (smoke v2 NG)。drag 中はガードして、Slider 等の外部経由の変化のみ
    // dragOrigin に反映する。
    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            // Phase 2.5g+h+i fixup v3: 縦長 image を横長 container に置くと letterbox で
            // 左右に余白ができる。normalized rect は「image 内の正規化座標」を意味するべきなので、
            // ZStack 内では image actual area (= imageRect) だけを 1.0 として扱う。
            let imageRect = AspectFitter.fittedBounds(
                sourceSize: image.size,
                in: geo.size
            )
            let viewW = imageRect.width
            let viewH = imageRect.height
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.15))
                    .frame(
                        width: normalizedRect.width * viewW,
                        height: normalizedRect.height * viewH
                    )
                    .position(
                        x: imageRect.minX + (normalizedRect.origin.x + normalizedRect.width / 2) * viewW,
                        y: imageRect.minY + (normalizedRect.origin.y + normalizedRect.height / 2) * viewH
                    )
                    .allowsHitTesting(false)
                // Phase 2.5g+h+i fixup v3: gesture catcher を image actual area に限定。
                // image の灰色 letterbox 領域では drag を受けず、image 内の座標系で
                // translation を正規化することで縦長 image でも矩形が image を超えない。
                Color.clear
                    .frame(width: viewW, height: viewH)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .local)
                            .onChanged { value in
                                if !isDragging {
                                    // 最初のフレームのみ dragOrigin を確定 (drag 開始時点の rect を snapshot)。
                                    // 以降のフレームでは下の onChange ガードにより dragOrigin が累積されない。
                                    dragOrigin = normalizedRect
                                    isDragging = true
                                }
                                let dx = value.translation.width / viewW
                                let dy = value.translation.height / viewH
                                var newRect = dragOrigin
                                newRect.origin.x = max(0, min(1 - newRect.width, dragOrigin.origin.x + dx))
                                newRect.origin.y = max(0, min(1 - newRect.height, dragOrigin.origin.y + dy))
                                normalizedRect = newRect
                            }
                            .onEnded { _ in
                                isDragging = false
                                dragOrigin = normalizedRect
                            }
                    )
            }
            .onAppear { dragOrigin = normalizedRect }
            .onChange(of: normalizedRect) { _, newValue in
                // drag 経由の更新は無視する。Slider 等の外部経由の変化だけ dragOrigin に同期。
                if !isDragging {
                    dragOrigin = newValue
                }
            }
        }
    }
}
