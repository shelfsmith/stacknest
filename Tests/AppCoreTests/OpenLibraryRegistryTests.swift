// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("OpenLibraryRegistry")
@MainActor
struct OpenLibraryRegistryTests {

    @Test("register returns true for new URL, false for duplicate")
    func registerDedup() {
        let registry = OpenLibraryRegistry.shared
        let url = URL(filePath: "/tmp/test-\(UUID().uuidString).stacknest")
        defer { registry.unregister(url) }
        #expect(registry.register(url) == true)
        #expect(registry.register(url) == false)
    }

    @Test("unregister allows re-register")
    func unregisterAllowsReregister() {
        let registry = OpenLibraryRegistry.shared
        let url = URL(filePath: "/tmp/test-\(UUID().uuidString).stacknest")
        defer { registry.unregister(url) }
        _ = registry.register(url)
        registry.unregister(url)
        #expect(registry.register(url) == true)
    }

    @Test("contains reports current state")
    func contains() {
        let registry = OpenLibraryRegistry.shared
        let url = URL(filePath: "/tmp/test-\(UUID().uuidString).stacknest")
        defer { registry.unregister(url) }
        #expect(registry.contains(url) == false)
        _ = registry.register(url)
        #expect(registry.contains(url) == true)
    }
}
