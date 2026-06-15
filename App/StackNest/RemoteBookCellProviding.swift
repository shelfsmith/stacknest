// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore

extension BookRow: BookCellProviding {
    public var playDateValue: Date? { playDate }
}

import LibraryServerAPI

extension BookListItemDTO: BookCellProviding {
    public var playDateValue: Date? { lastReadAt }
}
