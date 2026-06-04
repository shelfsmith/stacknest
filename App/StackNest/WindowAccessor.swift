// SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

/// NSView subclass that captures its hosting window when mounted.
/// Used to register TitleScreen windows with URLOpener.
final class WindowAccessorView: NSView {
    private let callback: (NSWindow) -> Void

    init(callback: @escaping (NSWindow) -> Void) {
        self.callback = callback
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = self.window {
            callback(window)
        }
    }
}

/// SwiftUI wrapper around WindowAccessorView.
/// Place this in a .background modifier to capture the hosting window.
struct WindowAccessor: NSViewRepresentable {
    let callback: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowAccessorView(callback: callback)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
