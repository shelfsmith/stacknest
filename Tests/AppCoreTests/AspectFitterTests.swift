// SPDX-License-Identifier: MIT
import Testing
import Foundation
import CoreGraphics
@testable import AppCore

@Suite("AspectFitter.fittedBounds")
struct AspectFitterTests {
    @Test
    func portraitInLandscapeContainer() {
        // 800×1200 portrait (aspect 2/3) in 1000×280 landscape container.
        // → image fits to height 280, width = 280 * (800/1200) ≈ 186.67
        // → x letterbox = (1000 - 186.67) / 2 ≈ 406.67, y = 0
        let r = AspectFitter.fittedBounds(
            sourceSize: CGSize(width: 800, height: 1200),
            in: CGSize(width: 1000, height: 280)
        )
        #expect(abs(r.size.height - 280) < 0.01)
        #expect(abs(r.size.width - (280.0 * 800.0 / 1200.0)) < 0.01)
        #expect(abs(r.origin.x - (1000 - r.size.width) / 2) < 0.01)
        #expect(abs(r.origin.y) < 0.01)
    }

    @Test
    func landscapeInLandscapeContainer() {
        // 3000×1200 landscape (aspect 2.5) in 1000×280 landscape container (aspect ≈ 3.57).
        // source aspect < container aspect → fits to height 280, width = 280*2.5 = 700.
        // x letterbox = (1000 - 700) / 2 = 150.
        let r = AspectFitter.fittedBounds(
            sourceSize: CGSize(width: 3000, height: 1200),
            in: CGSize(width: 1000, height: 280)
        )
        #expect(abs(r.size.height - 280) < 0.01)
        #expect(abs(r.size.width - 700) < 0.01)
        #expect(abs(r.origin.x - 150) < 0.01)
    }

    @Test
    func landscapeNarrowerThanContainer() {
        // 3000×1200 landscape (aspect 2.5) in 500×280 container (aspect ≈ 1.79).
        // source aspect > container aspect → fits to width 500, height = 500/2.5 = 200.
        // y letterbox = (280 - 200) / 2 = 40.
        let r = AspectFitter.fittedBounds(
            sourceSize: CGSize(width: 3000, height: 1200),
            in: CGSize(width: 500, height: 280)
        )
        #expect(abs(r.size.width - 500) < 0.01)
        #expect(abs(r.size.height - 200) < 0.01)
        #expect(abs(r.origin.x) < 0.01)
        #expect(abs(r.origin.y - 40) < 0.01)
    }

    @Test
    func squareInLandscapeContainer() {
        // 1000×1000 in 800×400 → height fills, width = 400.
        // x letterbox = (800 - 400)/2 = 200.
        let r = AspectFitter.fittedBounds(
            sourceSize: CGSize(width: 1000, height: 1000),
            in: CGSize(width: 800, height: 400)
        )
        #expect(abs(r.size.width - 400) < 0.01)
        #expect(abs(r.size.height - 400) < 0.01)
        #expect(abs(r.origin.x - 200) < 0.01)
        #expect(abs(r.origin.y) < 0.01)
    }

    @Test
    func handlesZeroSource() {
        let r = AspectFitter.fittedBounds(
            sourceSize: .zero,
            in: CGSize(width: 800, height: 400)
        )
        #expect(r == CGRect(origin: .zero, size: CGSize(width: 800, height: 400)))
    }

    @Test
    func handlesZeroContainer() {
        let r = AspectFitter.fittedBounds(
            sourceSize: CGSize(width: 100, height: 100),
            in: .zero
        )
        #expect(r == CGRect(origin: .zero, size: .zero))
    }
}
