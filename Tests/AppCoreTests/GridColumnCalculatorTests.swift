// SPDX-License-Identifier: MIT
import Testing
import Foundation
import CoreGraphics
@testable import AppCore

@Suite("GridColumnCalculator.columns")
struct GridColumnCalculatorTests {
    @Test
    func typicalCase() {
        // 600 wide / itemMinSize 110 / spacing 16
        // (600 + 16) / (110 + 16) = 4.888... → 4 列
        // 検算: 4 × 110 + 3 × 16 = 488 ≤ 600、5 × 110 + 4 × 16 = 614 > 600
        let n = GridColumnCalculator.columns(
            viewportWidth: 600,
            itemMinSize: 110,
            spacing: 16
        )
        #expect(n == 4)
    }

    @Test
    func clampsToOneWhenViewportSmallerThanItem() {
        // viewport が item より狭い → 数学的には 0 列だが、最低 1 を保証
        let n = GridColumnCalculator.columns(
            viewportWidth: 100,
            itemMinSize: 110,
            spacing: 16
        )
        #expect(n == 1)
    }

    @Test
    func clampsToOneWhenViewportIsZero() {
        // 極端な edge: viewport=0
        let n = GridColumnCalculator.columns(
            viewportWidth: 0,
            itemMinSize: 110,
            spacing: 16
        )
        #expect(n == 1)
    }

    @Test
    func largeItemFitsTwoColumns() {
        // 600 wide / itemMinSize 200 / spacing 16
        // (600 + 16) / (200 + 16) = 2.85... → 2 列
        let n = GridColumnCalculator.columns(
            viewportWidth: 600,
            itemMinSize: 200,
            spacing: 16
        )
        #expect(n == 2)
    }

    @Test
    func exactFitDoesNotOverflow() {
        // 4 × 110 + 3 × 16 = 488、viewport がぴったり 488 のとき 4 列、489 でも 4 列
        let n488 = GridColumnCalculator.columns(
            viewportWidth: 488,
            itemMinSize: 110,
            spacing: 16
        )
        #expect(n488 == 4)
        let n489 = GridColumnCalculator.columns(
            viewportWidth: 489,
            itemMinSize: 110,
            spacing: 16
        )
        #expect(n489 == 4)
    }
}
