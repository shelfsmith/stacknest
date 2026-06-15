// SPDX-License-Identifier: MIT
import SwiftUI

/// リスト表のセル描画に必要な列値を供給する。BookRow（ローカル）と BookListItemDTO（リモート）が
/// App ターゲットで適合する。playDate は供給元で意味が異なるため単一名 playDateValue に集約。
/// それ以外は両者の既存プロパティ名と一致させる。
public protocol BookCellProviding {
    var title: String { get }
    var rating: Int { get }
    var author: String? { get }
    var genre: String? { get }
    var dateAdded: Date { get }
    var playDateValue: Date? { get }
    var unseen: Bool { get }
    var bookType: Int { get }
    var neta: String? { get }
    var keywordA: String? { get }
    var keywordB: String? { get }
    var memo: String? { get }
    var series: String? { get }
    var volume: Double? { get }
}

/// 1 セルの SwiftUI 描画。ローカルとリモートで共有。現行ローカル cellContent と同一の見た目。
/// settings (LibrarySettings) が @MainActor 隔離のため本関数も @MainActor。
/// 呼び出し元 (cellContent / SwiftUI body) は元々メインアクタ上で実行される。
@MainActor
@ViewBuilder
public func bookCellView(_ col: BookColumn, provider p: BookCellProviding, settings: LibrarySettings) -> some View {
    switch col {
    case .title: Text(p.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
    case .rating: Text(p.rating > 0 ? String(repeating: "★", count: p.rating) : "").monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
    case .author: Text(p.author ?? "").lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
    case .genre: Text(p.genre ?? "").lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
    case .dateAdded: Text(p.dateAdded, format: .dateTime.year().month().day()).frame(maxWidth: .infinity, alignment: .leading)
    case .playDate:
        if let d = p.playDateValue { Text(d, format: .dateTime.year().month().day()).frame(maxWidth: .infinity, alignment: .leading) }
        else { Text("").frame(maxWidth: .infinity, alignment: .leading) }
    case .unseen: Text(p.unseen ? "●" : "").foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .center)
    case .bookType: Text(settings.bookTypeLabel(p.bookType)).frame(maxWidth: .infinity, alignment: .leading)
    case .neta: Text(p.neta ?? "").lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
    case .keywordA: Text(p.keywordA ?? "").lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
    case .keywordB: Text(p.keywordB ?? "").lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
    case .memo: Text((p.memo ?? "").replacingOccurrences(of: "\n", with: " ")).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    case .series: Text(p.series ?? "").lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
    case .volume: Text(p.volume.map { vol -> String in let intVal = Int(vol); return vol == Double(intVal) ? "\(intVal)" : String(vol) } ?? "").monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
    }
}
