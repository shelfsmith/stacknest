// SPDX-License-Identifier: MIT
import Hummingbird
import LibraryServerAPI

// 共有 DTO（Foundation のみ）にサーバ側でのみ Hummingbird ResponseEncodable を付与する。
extension BookPageDTO: ResponseEncodable {}
extension LibraryDTO: ResponseEncodable {}
extension ServerCapabilities: ResponseEncodable {}
extension ManifestDTO: ResponseEncodable {}
extension UnlockReply: ResponseEncodable {}
extension ShelfDTO: ResponseEncodable {}
extension BookDetailDTO: ResponseEncodable {}
extension AdjacentVolumeReply: ResponseEncodable {}
extension MeReply: ResponseEncodable {}
extension StampDefinitionsDTO: ResponseEncodable {}
extension StampApplyReply: ResponseEncodable {}
extension CoverCandidatesDTO: ResponseEncodable {}
