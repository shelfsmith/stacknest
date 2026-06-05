// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore

/// 「キーを押してください…」状態で次の keyDown を 1 回捕捉し CapturedBinding を返す。
/// Esc はキャンセル。`isCapturing` バインディングで呼び出し側が開始/終了を制御する。
struct KeyCaptureField: NSViewRepresentable {
    @Binding var isCapturing: Bool
    var onCapture: (CapturedBinding) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> CaptureNSView {
        let v = CaptureNSView()
        v.onCapture = { onCapture($0) }
        v.onCancel = { onCancel() }
        return v
    }

    func updateNSView(_ nsView: CaptureNSView, context: Context) {
        if isCapturing {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }

    final class CaptureNSView: NSView {
        var onCapture: ((CapturedBinding) -> Void)?
        var onCancel: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { // Esc cancels
                onCancel?()
                return
            }
            let captured = KeyCaptureClassifier.classify(
                keyCode: event.keyCode,
                modifiers: UInt(event.modifierFlags.rawValue),
                characters: event.charactersIgnoringModifiers
            )
            onCapture?(captured)
        }
    }
}
