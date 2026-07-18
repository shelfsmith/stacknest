// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import LibraryStore
import SwiftUI
import UniformTypeIdentifiers

/// Phase 2.6c: 初回起動ウィザード。ページ送り式（戻る/次へ・動的ドット）。
/// ①ようこそ → ②画像の開き方（内蔵/外部・スキップ可）→ ③内蔵ビューア設定（内蔵かつ
/// 非スキップ時のみ）→ ④最初のライブラリ（新規/開く/取り込み・「あとで」でタイトルへ）。
struct FirstRunWizardView: View {
    @Bindable var settings: ViewerSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var step: FirstRunWizardStep = .welcome
    @State private var flow = FirstRunWizardFlow()
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var libraryName = ""

    var body: some View {
        VStack(spacing: 0) {
            stepDots.padding(.top, 20)
            Divider().padding(.top, 12)

            Group {
                switch step {
                case .welcome: welcomeStep
                case .viewerChoice: viewerChoiceStep
                case .builtInSettings: builtInSettingsStep
                case .firstLibrary: firstLibraryStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            Divider()
            navBar.padding(16)
        }
        .frame(width: 560, height: 460)
        .alert("エラー", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Dots

    private var stepDots: some View {
        HStack(spacing: 8) {
            ForEach(flow.steps, id: \.self) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("StackNest へようこそ")
                .font(.system(size: 28, weight: .bold))
            Text("画像ライブラリ管理アプリです。\n最初に、本の開き方と最初のライブラリを設定します。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var viewerChoiceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("画像の開き方").font(.title2.bold())
            Text("本を開くときの方法を選びます。").foregroundStyle(.secondary)

            Picker("", selection: viewerChoiceBinding) {
                Text("内蔵ビューアで開く").tag(WizardViewerChoice.builtIn)
                Text("外部ビューアを指定する").tag(WizardViewerChoice.external)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if flow.viewerChoice == .external {
                HStack(spacing: 8) {
                    Button("アプリを選択…") { chooseExternalViewer() }
                    if let path = settings.externalViewerAppPath {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable().frame(width: 18, height: 18)
                        Text(FileManager.default.displayName(atPath: path))
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("(未選択 — 既定の挙動で開きます)")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                }
                .padding(.leading, 20)
            }

            Text("内蔵ビューアはアーカイブ／画像／フォルダ内の画像・PDF にのみ適用されます。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var builtInSettingsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("内蔵ビューアの設定").font(.title2.bold())
            Text("あとから設定画面でも変更できます。")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                BuiltInViewerSettingsForm(settings: settings)
            }
            .formStyle(.grouped)
        }
    }

    private var firstLibraryStep: some View {
        VStack(spacing: 16) {
            Text("最初のライブラリ").font(.title2.bold())
            Text("新しく作成するか、既存のライブラリを開きます。")
                .foregroundStyle(.secondary)
            VStack(spacing: 12) {
                TextField("ライブラリ名（任意）", text: $libraryName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button {
                    let trimmed = libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fileName = (trimmed.isEmpty ? "Untitled" : trimmed) + ".stacknest"
                    LibraryActions.createNew(defaultName: fileName, onOpen: { completeAndOpen($0) }, onError: { presentError($0, $1) })
                } label: {
                    Label("新しいライブラリを作成", systemImage: "plus.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    LibraryActions.openExisting(onOpen: { completeAndOpen($0) }, onError: { presentError($0, $1) })
                } label: {
                    Label("既存のライブラリを開く", systemImage: "folder.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    LibraryActions.importFromXML(onOpen: { completeAndOpen($0) }, onError: { presentError($0, $1) })
                } label: {
                    Label("Stackroom Library から取り込む", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 300)
        }
    }

    // MARK: - Nav

    private var navBar: some View {
        HStack {
            if flow.previous(before: step) != nil {
                Button("← 戻る") { goBack() }
            }
            Spacer()
            if step != .firstLibrary {
                Button("次へ →") { goNext() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("あとで（タイトル画面へ）") { laterToTitle() }
            }
        }
    }

    // MARK: - Bindings & actions

    private var viewerChoiceBinding: Binding<WizardViewerChoice> {
        Binding(
            get: { flow.viewerChoice },
            set: { newValue in
                flow.viewerChoice = newValue
                settings.useBuiltInViewer = (newValue == .builtIn)
            }
        )
    }

    private func chooseExternalViewer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            settings.externalViewerAppPath = url.path(percentEncoded: false)
        }
    }

    private func goNext() {
        if let n = flow.next(after: step) { step = n }
    }

    private func goBack() {
        if let p = flow.previous(before: step) { step = p }
    }

    private func completeAndOpen(_ url: URL) {
        AppPreferences.hasCompletedFirstRunWizard = true
        openWindow(value: url)
        dismiss()
    }

    private func laterToTitle() {
        AppPreferences.hasCompletedFirstRunWizard = true
        dismiss()
        openWindow(id: "title")
    }

    private func presentError(_ error: Error?, _ title: String) {
        errorMessage = error?.localizedDescription ?? title
        showError = true
    }
}
