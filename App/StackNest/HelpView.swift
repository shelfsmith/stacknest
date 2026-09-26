// SPDX-License-Identifier: MIT
import SwiftUI
import StackNestL10n

/// アプリ内ヘルプページ。メニューバー「ヘルプ ▸ StackNest ヘルプ」(⌘?) から
/// `openWindow(id: "help")` で表示する独立ウィンドウ。
/// 外部 README へのリンクではなく、アプリ自身が操作リファレンスを内包する。
/// 本文データは `HelpContent`（`Help/HelpContent.swift` 他）が持ち、このビューは描画のみを行う（G55）。
struct HelpView: View {
    @State private var keyVersion = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading

                ForEach(Array(HelpContent.sections(for: .current).enumerated()), id: \.offset) { _, helpSection in
                    section(helpSection.title) {
                        ForEach(Array(helpSection.blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(minWidth: 580, idealWidth: 660, minHeight: 540, idealHeight: 740)
        .onAppear { keyVersion += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .viewerKeyBindingsChanged)) { _ in keyVersion += 1 }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func blockView(_ block: HelpBlock) -> some View {
        switch block {
        case .para(let text):
            para(text)
        case .bullet(let text):
            bullet(text)
        case .keyRow(let action, let keys):
            keyRow(action, keys)
        case .viewerKeyTable:
            viewerKeyTable
        case .link(let label, let url):
            link(label, url)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(HelpContent.heading.title).font(.system(size: 22, weight: .bold))
            Text(HelpContent.heading.subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold))
            content()
        }
    }

    private func para(_ text: String) -> some View {
        Text(.init(text)).font(.system(size: 12.5)).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.system(size: 12.5))
            Text(.init(text)).font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keyRow(_ action: String, _ keys: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(keys).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(width: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(action).font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 内蔵ビューアのキー表は ViewerHelpOverlayView と単一ソースを共有する。
    private var viewerKeyTable: some View {
        let grouped = ViewerHelpOverlayView.grouped
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(grouped, id: \.section) { group in
                Text(group.section).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.secondary)
                ForEach(group.rows, id: \.action) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Text(row.keys).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .frame(width: 300, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(row.action).font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .id(keyVersion)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 8))
    }

    private func link(_ label: String, _ urlString: String) -> some View {
        Group {
            if let url = URL(string: urlString) {
                Link(label, destination: url).font(.system(size: 12.5))
            } else {
                Text(label).font(.system(size: 12.5))
            }
        }
    }
}
