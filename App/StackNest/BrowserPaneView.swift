// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import AppCore
import LibraryStore

/// Browser pane: 3 列の HStack + 下端の ResizeHandle で構成。
/// 高さは LibrarySettings.browserPaneState.height で永続化、user drag で 80...600pt の範囲。
struct BrowserPaneView: View {
    @Bindable var appState: AppState
    @Bindable var settings: LibrarySettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(0..<3) { i in
                    BrowserColumnView(
                        columnIndex: i,
                        appState: appState,
                        settings: settings
                    )
                    if i < 2 { Divider() }
                }
            }
            .frame(height: settings.browserPaneState.height)

            ResizeHandle(height: Bindable(settings).browserPaneState.height)
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
