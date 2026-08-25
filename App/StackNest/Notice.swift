// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit

/// ライブラリ窓の上端に出すお知らせ 1 枚分。
///
/// G39 の `FinderTagSyncNotice` を一般化したもの。**入口（文言を組む純粋関数）は
/// 用途ごとに分かれるが、出口（この型と表示と寿命）は 1 つにそろえる。**
struct Notice: Equatable {
    enum Kind: Equatable { case info, warning }

    var kind: Kind
    var text: String
    /// 「詳細」で開くアラートの本文（長い一覧はここへ）。
    var detail: String?
}

/// お知らせ 1 枠。表示中の `Notice` と、その自動消去タイマーを一緒に持つ。
///
/// ★ **寿命の規則をここだけに置く。**「info は消える／warning は消えない」を
/// 呼び出し側にコピーすると必ずずれる。ずれた結果は
/// **「警告が数秒で消えて見逃す」**という、この機能で一番避けたい壊れ方になる。
@MainActor
@Observable
final class NoticeSlot {
    private(set) var notice: Notice?
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    /// お知らせを出す。**警告は自動で消さない** —— 索引無効・取り込み失敗の類は
    /// 見逃したら二度と分からない。
    ///
    /// - Parameter autoDismissAfter: info を消すまでの時間。**引数にしてあるのはテストのため**
    ///   （固定 6 秒待ちのテストを書かないで済むように）。
    func present(_ notice: Notice, autoDismissAfter: Duration = .seconds(6)) {
        clearTask?.cancel()
        clearTask = nil
        self.notice = notice
        guard notice.kind == .info else { return }
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: autoDismissAfter)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// 手で閉じる／庫を閉じるときに呼ぶ。
    func dismiss() {
        clearTask?.cancel()
        clearTask = nil
        notice = nil
    }
}

/// 上端に出すバナー 1 枚。
///
/// **見た目は G39 の `FinderTagSyncBanner` そのまま**（実機 smoke で確認済みの表示なので変えない）。
struct NoticeBanner: View {
    let notice: Notice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: notice.kind == .warning ? "exclamationmark.triangle.fill" : "tag")
                .foregroundStyle(notice.kind == .warning ? Color.orange : Color.secondary)
            Text(notice.text)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: 520, alignment: .leading)
            if notice.detail != nil {
                Button("詳細") { showDetail() }
                    .buttonStyle(.link)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("この通知を閉じる")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.secondary.opacity(0.3)))
        .shadow(radius: 4)
    }

    private func showDetail() {
        let alert = NSAlert()
        alert.messageText = notice.text
        alert.informativeText = notice.detail ?? ""
        alert.runModal()
    }
}
