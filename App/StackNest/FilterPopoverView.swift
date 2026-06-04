// SPDX-License-Identifier: MIT
import SwiftUI
import LibraryStore

/// Filter popover の root view。各 row component を VStack で並べ、
/// 「全てクリア」ボタンで FilterState() に reset する。
struct FilterPopoverView: View {
    @Binding var filter: FilterState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("フィルタ").font(.headline)
                Spacer()
                Button("全てクリア") { filter = FilterState() }
                    .disabled(filter.isEmpty)
            }
            Divider()
            BookTypeFilterRow(bookTypes: $filter.bookTypes)
            Divider()
            UnseenFilterRow(unseen: $filter.unseen)
            Divider()
            RatingFilterRow(ratingMin: $filter.ratingMin)
            Divider()
            DateFilterRow(label: "登録日", range: $filter.dateAdded)
            DateFilterRow(label: "読んだ日", range: $filter.playDate)
        }
        .padding()
    }
}
