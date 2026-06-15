// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore
import LibraryServerAPI

extension BookRow: BookCellProviding {
    public var playDateValue: Date? { playDate }
}

extension BookListItemDTO: BookCellProviding {
    public var playDateValue: Date? { lastReadAt }
}
