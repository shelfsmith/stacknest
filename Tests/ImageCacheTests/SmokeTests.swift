import Testing
@testable import ImageCache

@Suite("ImageCache smoke tests")
struct ImageCacheSmokeTests {
    @Test("Module exposes a versioned identifier")
    func moduleHasVersion() {
        #expect(ImageCache.moduleVersion == "0.1.0")
    }
}
