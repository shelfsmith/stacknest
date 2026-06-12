// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore

/// Browser pane: 3 列の HStack + 下端の ResizeHandle で構成。
/// 高さは BrowserPaneState.height で永続化、user drag で 80...600pt の範囲。
///
/// Phase 4.2b-1b-2a: AppState/LibrarySettings 依存を排除。injected closures で backend-agnostic に。
struct BrowserPaneView: View {
    @Binding var browserPaneState: BrowserPaneState
    let labelFor: (BrowserPaneState.BrowseField) -> String
    let refreshKey: String
    let facetValues: (String, [(String, String)]) async -> [String]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<3) { i in
                    BrowserColumnView(
                        columnIndex: i,
                        browserPaneState: $browserPaneState,
                        labelFor: labelFor,
                        refreshKey: refreshKey,
                        facetValues: facetValues
                    )
                    if i < 2 { Divider() }
                }
            }
            .frame(height: browserPaneState.height)

            ResizeHandle(height: $browserPaneState.height)
                .frame(height: 4)
        }
    }
}

/// Browser pane の高さを user drag で resize する handle。
/// 80...600pt にクランプ、cursor は NSCursor.resizeUpDown。
///
/// Phase 2.4d R1: drag 開始時の高さを `dragStartHeight` に保存し、`value.translation.height`
/// (開始からの累積デルタ) を加算して計算する。以前は `height + value.translation.height`
/// で毎フレーム累積し、マウスを追い越して急変する不具合があった。
private struct ResizeHandle: View {
    @Binding var height: Double
    @State private var dragStartHeight: Double? = nil

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartHeight == nil {
                            dragStartHeight = height
                        }
                        let baseline = dragStartHeight ?? height
                        let proposed = baseline + value.translation.height
                        height = max(80, min(600, proposed))
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
    }
}
