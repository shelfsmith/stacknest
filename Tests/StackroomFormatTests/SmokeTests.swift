// SPDX-License-Identifier: MIT
import Testing
@testable import StackroomFormat

@Suite("StackroomFormat module presence")
struct StackroomFormatModulePresenceTests {
    @Test("Module exposes a versioned identifier")
    func moduleHasVersion() {
        #expect(StackroomFormat.moduleVersion == "0.1.0")
    }

    @Test("BookRecord type is reachable")
    func bookRecordReachable() {
        _ = BookRecord.self
    }
}
