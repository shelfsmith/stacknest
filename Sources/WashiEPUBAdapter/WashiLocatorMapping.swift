// SPDX-License-Identifier: MIT
import WashiCore
import EPUBAdapter

enum WashiLocatorMapping {
    static let engineName = "washi"
    static func toValue(_ l: EPUBLocator) -> EPUBLocatorValue {
        EPUBLocatorValue(spine: l.spineIndex, progress: l.progression, cfi: nil, engine: engineName)
    }
    static func toWashi(_ v: EPUBLocatorValue) -> EPUBLocator {
        let r = v.restorable(for: engineName)
        return EPUBLocator(spineIndex: r.spine, progression: r.progress, idref: nil)
    }
}
