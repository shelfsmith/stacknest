import Testing
@testable import AppCore

@Suite struct BatchDownloadPlanTests {
    @Test func pendingExcludesDownloadedAndSortsAscending() {
        let downloaded: Set<Int> = [2, 4]
        let result = BatchDownloadPlan.pending(selected: [4, 1, 2, 3]) { downloaded.contains($0) }
        #expect(result == [1, 3])
    }
    @Test func pendingEmptyWhenAllDownloaded() {
        let result = BatchDownloadPlan.pending(selected: [1, 2]) { _ in true }
        #expect(result.isEmpty)
    }
}
