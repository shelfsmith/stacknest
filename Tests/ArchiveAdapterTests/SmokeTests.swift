import Testing
@testable import ArchiveAdapter

@Suite("ArchiveAdapter smoke tests")
struct ArchiveAdapterSmokeTests {
    @Test("Module exposes a versioned identifier")
    func moduleHasVersion() {
        #expect(ArchiveAdapter.moduleVersion == "0.1.0")
    }

    @Test("Initial supported formats list is empty until Phase 2.2")
    func initialFormatsEmpty() {
        #expect(ArchiveAdapter.supportedFormats.isEmpty)
    }
}
