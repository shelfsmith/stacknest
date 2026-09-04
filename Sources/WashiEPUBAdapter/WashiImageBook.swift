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
        guard imagePaths.indices.contains(index) else { throw EPUBAdapterError.cannotOpen("page \(index) out of range") }
        return try publication.resource(at: imagePaths[index]).data
    }
}
