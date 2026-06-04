// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore
import LibraryStore

@Suite("ViewerEnums")
struct ViewerEnumsTests {
    @Test func pageDirectionRoundTripsRawValue() {
        #expect(PageDirection(rawValue: "rightToLeft") == .rightToLeft)
        #expect(PageDirection(rawValue: "leftToRight") == .leftToRight)
        #expect(PageDirection.rightToLeft.rawValue == "rightToLeft")
    }

    @Test func pageDirectionDefaultIsRightToLeft() {
        #expect(PageDirection.defaultValue == .rightToLeft)
    }

    @Test func endOfBookBehaviorRoundTripsRawValue() {
        #expect(EndOfBookBehavior(rawValue: "stop") == .stop)
        #expect(EndOfBookBehavior(rawValue: "nextBook") == .nextBook)
        #expect(EndOfBookBehavior(rawValue: "loop") == .loop)
    }

    @Test func endOfBookBehaviorDefaultIsStop() {
        #expect(EndOfBookBehavior.defaultValue == .stop)
    }
}
