import Testing
@testable import RemoteClient

@Suite struct BookFileProgressTests {
    @Test func fraction() {
        #expect(RemoteLibraryClient.downloadFraction(received: 0, total: 100) == 0.0)
        #expect(RemoteLibraryClient.downloadFraction(received: 50, total: 100) == 0.5)
        #expect(RemoteLibraryClient.downloadFraction(received: 100, total: 100) == 1.0)
        #expect(RemoteLibraryClient.downloadFraction(received: 10, total: 0) == nil)
    }
}
