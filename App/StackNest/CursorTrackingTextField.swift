// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit

/// NSTextField wrapper that exposes cursor selection so that programmatic
/// insertion (e.g., "insert token" menu) can be applied at the current
/// cursor position rather than always appending to end.
struct CursorTrackingTextField: NSViewRepresentable {
    @Binding var text: String
    /// Updated on every selection change. Pass-back so the parent view can
    /// call `insertToken` later.
    @Binding var selectedRange: NSRange

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CursorTrackingTextField
        weak var textField: NSTextField?

        init(_ parent: CursorTrackingTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
            if let editor = field.currentEditor() as? NSTextView {
                parent.selectedRange = editor.selectedRange
            }
        }

        @objc func textViewSelectionChanged(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Confirm it belongs to our field editor
            guard textField?.currentEditor() === tv else { return }
            parent.selectedRange = tv.selectedRange
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isSelectable = true
        context.coordinator.textField = field
        // Observe selection changes via NSTextView (the field editor)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.textViewSelectionChanged(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: nil
        )
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }
}
