import AppCore
import AppKit
import LibraryServerAPI
import LibraryStore
import os
import StackroomFormat
import SwiftUI
import UniformTypeIdentifiers

/// The initial title screen shown when the app opens with no active library.
/// Provides three buttons: Create New Library, Open Existing Library, and Import from Stackroom XML.
struct TitleScreenView: View {
  static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "TitleScreen")

  @Environment(\.openWindow) var openWindow
  @State private var showError = false
  @State private var errorMessage = ""
  @State private var showConnectSheet = false
  /// 複数ライブラリ共有時のピッカー用。接続成功後に setする。
  @State private var pickerLibraries: [LibraryDTO] = []
  @State private var pickerServerID: UUID?

  var body: some View {
    titleContent
      .frame(width: 600, height: 500)
      .alert("Error", isPresented: $showError) {
        Button("OK") { }
      } message: {
        Text(errorMessage)
      }
      .sheet(isPresented: $showConnectSheet) {
        ConnectServerSheet { conn, libs in
          handleConnected(conn: conn, libs: libs)
        }
      }
      .sheet(isPresented: Binding(
        get: { !pickerLibraries.isEmpty },
        set: { if !$0 { pickerLibraries = [] } }
      )) {
        libraryPicker
      }
      .onReceive(NotificationCenter.default.publisher(for: .connectToServer)) { _ in
        showConnectSheet = true
      }
      .task {
        Self.logger.info("Title mounted, registering handler")
        URLOpener.shared.register { url in
          openWindow(value: url)
        }
      }
      .background(
        WindowAccessor { window in
          URLOpener.shared.registerTitleWindow(window)
        }
      )
  }

  private var titleContent: some View {
    VStack(spacing: 40) {
      VStack(spacing: 12) {
        Text("StackNest")
          .font(.system(size: 48, weight: .bold, design: .default))
        Text("画像ライブラリ管理")
          .font(.system(size: 18, weight: .regular))
          .foregroundStyle(.secondary)
      }
      .padding(.top, 40)

      VStack(spacing: 16) {
        Button(action: createNewLibrary) {
          Label("新しいライブラリを作成", systemImage: "plus.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)

        Button(action: openExistingLibrary) {
          Label("既存のライブラリを開く", systemImage: "folder.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        Button(action: importFromStackroomXML) {
          Label("Stackroom Library から取り込む", systemImage: "arrow.down.circle")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)

        Button { showConnectSheet = true } label: {
          Label("サーバに接続…", systemImage: "network")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
      .frame(maxWidth: 300)
      .padding(.vertical, 20)

      Spacer()
    }
  }

  // MARK: - Remote

  /// 接続成功時のハンドラ。共有ライブラリ数に応じてウィンドウを開く / ピッカーを出す。
  private func handleConnected(conn: ServerConnection, libs: [LibraryDTO]) {
    if libs.isEmpty {
      presentError(nil, title: "共有なし", message: "共有中のライブラリがありません")
    } else if libs.count == 1 {
      openWindow(value: RemoteLibraryRef(serverID: conn.id, libraryUUID: libs[0].id))
    } else {
      pickerServerID = conn.id
      pickerLibraries = libs
    }
  }

  @ViewBuilder
  private var libraryPicker: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("ライブラリを選択").font(.headline)
      List(pickerLibraries, id: \.id) { lib in
        HStack {
          Image(systemName: lib.locked ? "lock.fill" : "books.vertical")
          VStack(alignment: .leading) {
            Text(lib.name)
            Text("\(lib.bookCount) 件").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("開く") {
            if let sid = pickerServerID {
              openWindow(value: RemoteLibraryRef(serverID: sid, libraryUUID: lib.id))
            }
            pickerLibraries = []
          }
        }
      }
      .frame(height: 200)
      HStack {
        Spacer()
        Button("キャンセル") { pickerLibraries = [] }
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  // MARK: - Actions

  private func createNewLibrary() {
    LibraryActions.createNew(
      onOpen: { openWindow(value: $0) },
      onError: { presentError($0, title: $1) }
    )
  }

  private func openExistingLibrary() {
    LibraryActions.openExisting(
      onOpen: { openWindow(value: $0) },
      onError: { presentError($0, title: $1) }
    )
  }

  private func importFromStackroomXML() {
    LibraryActions.importFromXML(
      onOpen: { openWindow(value: $0) },
      onError: { presentError($0, title: $1) }
    )
  }

  private func presentError(_ error: Error?, title: String = "Error",
                            message: String? = nil) {
    if let message = message {
      errorMessage = message
    } else if let error = error {
      errorMessage = error.localizedDescription
    } else {
      errorMessage = "An unknown error occurred"
    }
    showError = true
  }
}

#Preview {
  TitleScreenView()
}
