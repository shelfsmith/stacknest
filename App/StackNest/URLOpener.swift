// SPDX-License-Identifier: MIT
import AppKit
import Foundation
import os
import Observation

/// Singleton broker between AppDelegate's `application(_:open:)` callback and SwiftUI's
/// `openWindow` environment. AppDelegate calls `enqueue(_:)` for incoming URLs.
/// SwiftUI views (TitleScreen, LibraryWindowContainer) call `register(_:)` to provide
/// an `openWindow(value:)` handler. URLs queued before a handler is registered are
/// flushed in arrival order on the next `register(_:)` call.
@MainActor
final class URLOpener {
    static let shared = URLOpener()
    private let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "URLOpener")
    private init() {}

    private var handler: ((URL) -> Void)?
    private var pendingURLs: [URL] = []
    private var titleWindows: Set<NSWindow> = []

    /// True if there are pending URLs queued from launch (before handler registration).
    var hasPendingURLs: Bool { !pendingURLs.isEmpty }

    /// Called by AppDelegate.application(_:open:) for each `.stacknest` URL.
    func enqueue(_ url: URL) {
        logger.info("enqueue: \(url.path) — handler=\(self.handler == nil ? "nil" : "set")")
        if let handler {
            handler(url)
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                closeAllTitleWindows()
            }
        } else {
            pendingURLs.append(url)
            logger.info("queued: pendingCount=\(self.pendingURLs.count)")
        }
    }

    /// Called by SwiftUI views via `.task` to install/refresh the open handler.
    /// Flushes any URLs that arrived before this registration.
    func register(_ newHandler: @escaping (URL) -> Void) {
        logger.info("register: pendingCount=\(self.pendingURLs.count)")
        handler = newHandler
        let toFlush = pendingURLs
        pendingURLs.removeAll()

        // If there are URLs to flush, hide title windows immediately before opening Library
        if !toFlush.isEmpty {
            hideAllTitleWindows()
        }

        for url in toFlush {
            newHandler(url)
        }
        if !toFlush.isEmpty {
            logger.info("register: flushed \(toFlush.count) URLs")
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                closeAllTitleWindows()
            }
        }
    }

    /// Register a title window so it can be closed after a URL redirect.
    func registerTitleWindow(_ window: NSWindow) {
        titleWindows.insert(window)
        // If there are already pending URLs (launch URL from app delegate),
        // hide this title window immediately to prevent flash.
        if hasPendingURLs {
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    /// Hide all registered title windows (set alpha to 0 and orderOut).
    private func hideAllTitleWindows() {
        for window in titleWindows {
            window.alphaValue = 0
            window.orderOut(nil)
        }
    }

    /// Close all registered title windows.
    private func closeAllTitleWindows() {
        logger.info("closeAllTitleWindows: \(self.titleWindows.count) windows")
        let windows = titleWindows
        titleWindows.removeAll()
        for window in windows {
            window.orderOut(nil)
        }
    }
}
