// SPDX-License-Identifier: MIT
import Foundation
import EPUBAdapter
import WashiCore

/// G48-2b: 全ページ画像の EPUB を開いた状態で抱える。`EPUBPublication` は open 後は不変（Sendable）。
final class WashiImageBook: EPUBImageBookReading {
    private let publication: EPUBPublication
    private let imagePaths: [String]        // spine 順の画像コンテナパス
    let spreads: [EPUBPageSpread]
    let readingDirection: EPUBReadingDirection

    init(publication: EPUBPublication, imagePaths: [String], spreads: [EPUBPageSpread]) {
        self.publication = publication
        self.imagePaths = imagePaths
        self.spreads = spreads
        self.readingDirection = WashiEPUBReader.direction(rawValue: publication.readingDirection.rawValue)
    }
    var pageCount: Int { imagePaths.count }
    func imageData(at index: Int) async throws -> Data {
        guard imagePaths.indices.contains(index) else {
            // Minor #2: 何が起きたかを明示する（"開けない" ではなく "index が範囲外"）。
            throw EPUBAdapterError.cannotOpen("imageData(at:) index \(index) is out of range for a \(imagePaths.count)-page image book")
        }
        return try publication.resource(at: imagePaths[index]).data
    }
}
