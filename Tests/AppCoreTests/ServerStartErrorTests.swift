import Testing
import Foundation
@testable import AppCore

@Suite struct ServerStartErrorTests {
    @Test func classifiesAddressInUseByErrno() {
        let e = POSIXError(.EADDRINUSE)
        #expect(ServerStartError.classify(e, port: 50000) == .portInUse(50000))
    }
    @Test func classifiesAddressInUseByMessage() {
        struct Dummy: Error, CustomStringConvertible { var description: String }
        let e = Dummy(description: "bind failed: Address already in use (errno: 48)")
        #expect(ServerStartError.classify(e, port: 50000) == .portInUse(50000))
    }
    @Test func otherErrorIsGeneric() {
        struct Dummy: Error, CustomStringConvertible { var description = "some other failure" }
        let e = Dummy()
        if case .generic = ServerStartError.classify(e, port: 50000) {} else {
            Issue.record("expected .generic")
        }
    }
}
