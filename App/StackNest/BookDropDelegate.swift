// SPDX-License-Identifier: MIT
import SwiftUI
import UniformTypeIdentifiers
import AppCore  // BookCategory.supportedExtensions

struct BookDropDelegate: DropDelegate {
    let onDrop: ([URL]) -> Void

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    urls.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let filtered = urls.filter { Self.isAcceptable(url: $0) }
            if !filtered.isEmpty {
                onDrop(filtered)
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    private static func isAcceptable(url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        if isDir.boolValue { return true }
        let ext = url.pathExtension.lowercased()
        return BookCategory.supportedExtensions.contains(ext)
    }
}
