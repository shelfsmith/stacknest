// SPDX-License-Identifier: MIT
import Hummingbird
import LibraryServerAPI
import StackroomFormat

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
extension LabelSettingsDTO: ResponseEncodable {}
extension AddBooksReplyDTO: ResponseEncodable {}
extension SmartShelfConditions: ResponseEncodable {}
extension WatchConfigDTO: ResponseEncodable {}
extension ImportConfigDTO: ResponseEncodable {}
extension GlobalImportConfigDTO: ResponseEncodable {}
extension DuplicateScanReply: ResponseEncodable {}
extension GrantDTO: ResponseEncodable {}
extension LibraryCountsDTO: ResponseEncodable {}
extension GeneralSettingsDTO: ResponseEncodable {}
extension IntegrityCheckDTO: ResponseEncodable {}
extension PresetSetDTO: ResponseEncodable {}
