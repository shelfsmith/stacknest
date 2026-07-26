// SPDX-License-Identifier: MIT
import Testing
@testable import StackroomFormat

@Suite("StackroomFormat module presence")
struct StackroomFormatModulePresenceTests {
    @Test("BookRecord type is reachable")
    func bookRecordReachable() {
        _ = BookRecord.self
    }
}
