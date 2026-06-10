// SPDX-License-Identifier: MIT
import SwiftUI
import CoreImage.CIFilterBuiltins

/// 文字列を QR 画像化して表示（ペアリング URL 用）。
/// CoreImage の QR generator を使う（App 層なので AppKit/CoreImage 利用可）。
struct QRCodeView: View {
    let content: String
    var size: CGFloat = 160

    var body: some View {
        if let image = Self.generate(content) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: size, height: size)
                .accessibilityLabel("ペアリング QR コード")
        } else {
            Text("QR 生成失敗")
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }

    private static func generate(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // 8x 拡大して滲みのない QR にする（.interpolation(.none) と合わせる）。
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
