// SPDX-License-Identifier: MIT
import WashiCore
import EPUBAdapter

enum WashiLocatorMapping {
    static let engineName = "washi"
    /// G56-S2: 文の位置（textOffset）があれば `cfi` に詰める。無ければ従来どおり spine＋progress だけ。
    static func toValue(_ l: EPUBLocator) -> EPUBLocatorValue {
        let cfi = l.textOffset.map { WashiTextAnchorCodec.encode(textOffset: $0, idref: l.idref) }
        return EPUBLocatorValue(spine: l.spineIndex, progress: l.progression, cfi: cfi, engine: engineName)
    }
    /// G56-S2: `idref` を必ず渡す。Washi の `EPUBPublication.resolve` は idref が nil だと textOffset を捨てる。
    static func toWashi(_ v: EPUBLocatorValue) -> EPUBLocator {
        let r = v.restorable(for: engineName)
        let anchor = WashiTextAnchorCodec.decode(r.cfi)
        return EPUBLocator(spineIndex: r.spine, progression: r.progress,
                           idref: anchor?.idref, textOffset: anchor?.textOffset)
    }
}
