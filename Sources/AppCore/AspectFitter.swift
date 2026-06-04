// SPDX-License-Identifier: MIT
import Foundation
import CoreGraphics

/// Phase 2.5g+h+i fixup v3: container 内に source を aspectFit したときの
/// 実描画 rect (origin = letterbox offset, size = actual image area) を返す純粋関数。
/// CoverCropPicker が「image area を 1.0 とする正規化座標」を提供するために使用する。
public enum AspectFitter {
    public static func fittedBounds(sourceSize: CGSize, in container: CGSize) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        guard container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: .zero)
        }
        let sourceAspect = sourceSize.width / sourceSize.height
        let containerAspect = container.width / container.height
        if sourceAspect > containerAspect {
            // source は container より横長 (相対的に) → 幅一杯、上下に余白
            let w = container.width
            let h = w / sourceAspect
            let y = (container.height - h) / 2
            return CGRect(x: 0, y: y, width: w, height: h)
        } else {
            // source は container より縦長 (相対的に) → 高さ一杯、左右に余白
            let h = container.height
            let w = h * sourceAspect
            let x = (container.width - w) / 2
            return CGRect(x: x, y: 0, width: w, height: h)
        }
    }
}
