// SPDX-License-Identifier: MIT
import SwiftUI

/// Filter popover のレート行。「無効 / — / ≥1 / ... / ≥5」の 7 ボタン。
struct RatingFilterRow: View {
    @Binding var ratingMin: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("レート").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Button("無効") { ratingMin = nil }
                    .buttonStyle(.bordered)
                    .tint(ratingMin == nil ? .accentColor : .secondary)
                Button("—") { ratingMin = 0 }
                    .buttonStyle(.bordered)
                    .tint(ratingMin == 0 ? .accentColor : .secondary)
                ForEach(1...5, id: \.self) { n in
                    Button("≥\(n)") { ratingMin = n }
                        .buttonStyle(.bordered)
                        .tint(ratingMin == n ? .accentColor : .secondary)
                }
            }
        }
    }
}
