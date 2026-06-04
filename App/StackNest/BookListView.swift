// SPDX-License-Identifier: MIT
import SwiftUI
import AppCore
import LibraryStore

/// SwiftUI entry point for the list view. Delegates to BookTableViewRepresentable
/// (NSTableView wrapper) to avoid the macOS Tahoe SwiftUI Table reentrancy bug.
struct BookListView: View {
    @Bindable var appState: AppState
    @Bindable var settings: LibrarySettings

    var body: some View {
        BookTableViewRepresentable(appState: appState, settings: settings)
    }
}
