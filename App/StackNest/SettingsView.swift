// SPDX-License-Identifier: MIT
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AppCore
import LibraryStore

struct SettingsView: View {
    @Bindable var settings: ViewerSettings
    @Environment(\.openWindow) private var openWindow
    @AppStorage(StartupMode.userDefaultsKey) private var startupRaw: String = StartupMode.default.rawValue
    @AppStorage(StartupMode.fixedLibraryURLKey) private var fixedURLString: String = ""
    // @AppStorage で UserDefaults を直接観察。NSAlert suppression checkbox 経由で
    // UserDefaults が変更されても KVO で自動再描画され、Settings の Toggle と同期する。
    @AppStorage(AppPreferences.confirmDeleteFromLibraryKey) private var confirmDeleteFromLibrary: Bool = true

    /// Phase 2.5g+h+i fixup v3 micro-fix: 厚い本判定閾値 TextField の入力中表示。
    /// TextField(value:format:) を直接使うと内容長で intrinsic content size が変動し
    /// HStack の他要素を押し出す (smoke v4 自由記載)。`text:` に切り替えて文字数を 3 桁
    /// (= 100 まで) に強制し、確定時に Int 変換 + setter clamp で同期する。
    @State private var thresholdInput: String = ""

    /// 現在表示中の設定タブ (0=一般 / 1=表示 / 2=取り込み)。
    /// SettingsWindowFixedSize にこの値を渡してタブ切替時に updateNSView を再発火させ、
    /// window 高さをアクティブタブのフィット高さに追従させる (TabView は active page のみ
    /// mount するため、最初のタブの高さに固定すると他タブで clip / 余白が生じる)。
    /// DEFAULT-OPEN = 一般 tab (tag=0)。
    @State private var settingsTab = 0

    /// 各 row の左端ラベル幅 (px)。caption の indent もこの値+spacing で揃える。
    /// 「指定ライブラリ」(7文字) 等の最長ラベルを 1 行に収める想定で 110pt。
    private let labelColumnWidth: CGFloat = 110

    var body: some View {
        TabView(selection: $settingsTab) {
            // MARK: - Tab 1: 一般
            Form {
                Section("起動時") {
                    let startupMode = StartupMode(rawValue: startupRaw) ?? .default
                    Picker(selection: Binding(
                        get: { startupMode },
                        set: { startupRaw = $0.rawValue }
                    )) {
                        Text("タイトル画面を表示").tag(StartupMode.titleScreen)
                        Text("前回開いていたライブラリを開く").tag(StartupMode.lastOpened)
                        Text("指定ライブラリを毎回開く").tag(StartupMode.fixedLibrary)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    // 「指定ライブラリ」row は常に表示し、選択モード以外では grey out する。
                    // 動的に row を出し入れすると window 高さが変わって smoke v14 で scrollbar が出たため、
                    // 静的 UI にして window max height を固定化する。
                    // .disabled() は button にしか visual grey out を伝播しないので、Text も含めて
                    // 半透明化するため .opacity を併用 (smoke v15 で label / path text が黒のまま残ったため)。
                    pathSettingsRow(
                        label: "指定ライブラリ",
                        pathString: fixedURLString.isEmpty ? "" : (URL(string: fixedURLString)?.path(percentEncoded: false) ?? fixedURLString),
                        placeholder: "ライブラリを選択してください",
                        onChoose: { chooseFixedLibrary() }
                    )
                    .disabled(startupMode != .fixedLibrary)
                    .opacity(startupMode == .fixedLibrary ? 1.0 : 0.4)
                }

                Section("操作") {
                    Toggle("ライブラリから削除前に確認ダイアログを表示", isOn: $confirmDeleteFromLibrary)
                }

                Section("初回ウィザード") {
                    Button("初回ウィザードを表示") {
                        AppPreferences.hasCompletedFirstRunWizard = false
                        openWindow(id: "wizard")
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("一般", systemImage: "power")
            }
            .tag(0)

            // MARK: - Tab 2: 表示
            Form {
                Section("画像ビューワ") {
                    // D5: section header "画像ビューワ", label "ビューワ", caption row
                    Picker("ビューワ", selection: $settings.useBuiltInViewer) {
                        Text("内蔵ビューワ").tag(true)
                        Text("外部ビューワ").tag(false)
                    }
                    .pickerStyle(.radioGroup)

                    Text("内蔵ビューワはアーカイブ／画像／フォルダ内の画像・PDF にのみ適用されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    BuiltInViewerSettingsForm(settings: settings)
                }

                Section("外部ビューワ") {
                    viewerSettingsRow(
                        label: "デフォルト",
                        caption: "各種類別ビューワが未設定の book はこの設定で開かれます。",
                        path: settings.externalViewerAppPath,
                        onChoose: { chooseDefaultViewer() },
                        onReset: settings.externalViewerAppPath != nil
                            ? { settings.externalViewerAppPath = nil }
                            : nil
                    )
                    ForEach(BookCategory.allCases, id: \.self) { category in
                        viewerSettingsRow(
                            label: category.displayName,
                            caption: category.extensionsHint,
                            path: settings.categoryViewerPaths[category],
                            onChoose: { chooseCategoryViewer(category) },
                            onReset: settings.categoryViewerPaths[category] != nil
                                ? { settings.categoryViewerPaths.removeValue(forKey: category) }
                                : nil
                        )
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("表示", systemImage: "eye")
            }
            .tag(1)

            // MARK: - Tab 3: 取り込み
            Form {
                Section("書籍追加時の挙動") {
                    Toggle("本の種類を自動分類する", isOn: $settings.autoClassifyEnabled)
                    HStack {
                        Text("厚い本判定閾値 (ページ数)")
                        Spacer()
                        TextField("", text: $thresholdInput)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .lineLimit(1)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            .onChange(of: thresholdInput) { _, newValue in
                                // 数字以外を弾く + 最大 3 文字に強制
                                // (5...100 範囲なので 3 桁あれば十分、layout 崩れを物理的に防ぐ)
                                let cleaned = String(newValue.filter(\.isNumber).prefix(3))
                                if cleaned != newValue {
                                    thresholdInput = cleaned
                                }
                            }
                            .onSubmit { commitThresholdInput() }
                        Stepper(
                            "",
                            value: $settings.thickBookThreshold,
                            in: 5...100,
                            step: 1
                        )
                        .labelsHidden()
                    }
                    .disabled(!settings.autoClassifyEnabled)
                    .opacity(settings.autoClassifyEnabled ? 1.0 : 0.5)
                    .onAppear { thresholdInput = String(settings.thickBookThreshold) }
                    .onChange(of: settings.thickBookThreshold) { _, newValue in
                        // Stepper 経由などで設定値が変わった場合に TextField を同期
                        let synced = String(newValue)
                        if thresholdInput != synced {
                            thresholdInput = synced
                        }
                    }
                    Text("OFF にすると、フォルダは画像セット、それ以外は厚い本として登録されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("取り込み", systemImage: "tray.and.arrow.down")
            }
            .tag(2)

            // MARK: - Tab 4: キー（キー設定は内蔵ビューワ専用。外部選択時はグレーアウト）
            KeyBindingsSettingsView(enabled: settings.useBuiltInViewer)
                .tabItem {
                    Label("キー", systemImage: "keyboard")
                }
                .tag(3)
        }
        // 横は 600pt 完全固定（「キー」タブのキーチップ＋ボタン行が折り返さない幅）。
        // 縦は SettingsWindowFixedSize 側でアクティブタブのフィット高さに追従させる (grow / shrink 両方向)。
        // tab: settingsTab を渡すことで、タブ切替時に updateNSView が再発火する。
        .frame(width: 600)
        .background(SettingsWindowFixedSize(tabBarPadding: 32, tab: settingsTab))
    }

    // MARK: - Row builders

    @ViewBuilder
    private func viewerSettingsRow(
        label: String,
        caption: String,
        path: String?,
        onChoose: @escaping () -> Void,
        onReset: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label)
                    .frame(width: labelColumnWidth, alignment: .leading)
                if let path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text(FileManager.default.displayName(atPath: path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                } else {
                    Text("(デフォルトを使用)")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let onReset {
                    Button("リセット") { onReset() }
                        .controlSize(.small)
                }
                Button("変更…") { onChoose() }
                    .controlSize(.small)
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, labelColumnWidth + 8)
        }
    }

    @ViewBuilder
    private func pathSettingsRow(
        label: String,
        pathString: String,
        placeholder: String,
        onChoose: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: labelColumnWidth, alignment: .leading)
            Text(pathString.isEmpty ? placeholder : pathString)
                .foregroundStyle(pathString.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(pathString.isEmpty ? "" : pathString)
            Spacer(minLength: 8)
            Button("変更…") { onChoose() }
                .controlSize(.small)
        }
    }

    // MARK: - Actions

    private func chooseDefaultViewer() {
        if let url = runViewerPicker() {
            settings.externalViewerAppPath = url.path(percentEncoded: false)
        }
    }

    private func chooseCategoryViewer(_ category: BookCategory) {
        if let url = runViewerPicker() {
            settings.categoryViewerPaths[category] = url.path(percentEncoded: false)
        }
    }

    private func runViewerPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func chooseFixedLibrary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("app.shelfsmith.stacknest.library") ?? .package]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            fixedURLString = url.absoluteString
        }
    }

    /// Phase 2.5g+h+i fixup v3 micro-fix: TextField の入力を Int に変換し setter に渡す。
    /// setter が 5...100 に clamp、@Observable が thickBookThreshold の変化を thresholdInput
    /// に同期する (.onChange(of:) 経由) ので、空文字や parse 失敗時も自動で元値に戻る。
    private func commitThresholdInput() {
        if let v = Int(thresholdInput) {
            settings.thickBookThreshold = v
        }
        // 空文字 or 非数値の場合は元値を表示し直す
        thresholdInput = String(settings.thickBookThreshold)
    }

}

/// 設定 window のサイズを AppKit の resize event 直 hook で制御する。
///
/// 達成: 横 460pt 完全固定 + 縦はアクティブタブの scrollbar が出ない高さに追従 (grow/shrink) +
/// 最小まで縮小可。
///
/// v11 までは `window.minSize/maxSize` で範囲指定したが、SwiftUI scene の
/// `.windowResizability(...)` が我々の設定を override して resize 復活する事象が観測された
/// (smoke v11 で「また任意にリサイズ出来る状態に戻った」)。よって `NSWindowDelegate` の
/// `windowWillResize(_:to:)` を直接 hook して **resize event 中にリアルタイム clamp** に切り替える。
/// この event は AppKit が必ず呼ぶ最終的な resize 決定点で、scene 側の override も上書きされない。
///
/// SwiftUI が既に NSWindow.delegate を設定済の可能性があるため、proxy 構造で:
///   - `windowWillResize` だけ自前で override (横は 460 / 縦は [min, max] に clamp)
///   - その他の delegate method は `forwardingTarget` で SwiftUI 側 delegate に転送
/// これで SwiftUI scene の close/minimize 等の handling は壊さない。
///
/// TabView 対応 (Phase 2.6b-2-4 fixup): NSTabView は active page のみ mount するため、
/// documentHeight は **現在表示中タブ** の真サイズになる。よって `tab` を stored property に
/// 持ち、タブ切替で updateNSView を再発火させ、window をアクティブタブの fitted 高さへ
/// **grow / shrink 両方向** で snap する (最初のタブ高さに固定すると、より高いタブで clip し
/// scrollbar が出る / より低いタブで余白が出る)。
private struct SettingsWindowFixedSize: NSViewRepresentable {
    private let fixedWidth: CGFloat = 600
    private let minHeight: CGFloat = 240
    /// documentView.frame.height に加える余裕。
    /// 24pt では smoke v13 でわずかに scrollbar が残ったため 48pt に増量。
    /// Form (.grouped) の最終 row 下端余白や section gap が documentView frame に
    /// 含まれない分のバッファ。TabView の tab bar 分 (macOS で ~28-34pt) を tabBarPadding で加算。
    private let heightPadding: CGFloat
    private let tabBarPadding: CGFloat
    /// 現在のタブ index。値が変わると SwiftUI が updateNSView を再呼び出しし、
    /// アクティブタブの高さへ追従できる (この struct が値を読まなくても、
    /// stored property の変化が再描画トリガになる)。
    let tab: Int

    init(tabBarPadding: CGFloat = 0, tab: Int = 0) {
        self.tabBarPadding = tabBarPadding
        self.heightPadding = 48 + tabBarPadding
        self.tab = tab
    }

    func makeCoordinator() -> ResizeDelegate {
        ResizeDelegate(fixedWidth: fixedWidth, minHeight: minHeight)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view.window, delegate: context.coordinator) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: nsView.window, delegate: context.coordinator) }
    }

    private func apply(to window: NSWindow?, delegate: ResizeDelegate) {
        guard let window else { return }
        window.setFrameAutosaveName("")
        window.styleMask.insert(.resizable)

        // SwiftUI 側が設定した delegate を proxy 経由で残しつつ、windowWillResize は自前で奪う。
        if window.delegate !== delegate {
            delegate.proxyTarget = window.delegate
            window.delegate = delegate
        }

        guard let contentView = window.contentView else { return }

        // Form (.grouped) は内部に NSScrollView を持ち、その documentView の frame.height が
        // **scroll content の真サイズ** (= 全項目を表示しきる高さ)。これを使わないと、
        // fittingSize は ScrollView viewport size (現 window 高さ依存) を返し、循環参照で
        // max が現高さに張り付いて全項目を表示できなかった (smoke v12 で観測)。
        // 「キー」タブも他タブ同様 documentView 全高に追従（ScrollView は maxHeight:.infinity で充填）。
        // これで全行が収まる高さに window が伸び、スクロール不要になる（画面より高い場合のみ内部スクロール）。
        let documentHeight = Self.findScrollViewDocumentHeight(in: contentView)
        let baseHeight = documentHeight ?? contentView.fittingSize.height
        guard baseHeight > 0 else { return }

        // アクティブタブの fitted 高さ。tab bar 分も含めた全項目を表示しきる高さ。
        let fittedHeight = baseHeight + heightPadding
        delegate.maxHeight = fittedHeight

        // window.minSize/maxSize も併用 (scene が override する前提だが保険として残す)。
        window.minSize = NSSize(width: fixedWidth, height: minHeight)
        window.maxSize = NSSize(width: fixedWidth, height: fittedHeight)

        // 横ズレ、または現高さがアクティブタブの fitted 高さと ~1pt 超ズレている場合に snap。
        // TabView では active page のみ mount するため、タブ切替ごとに fittedHeight が変わる。
        // grow (より高いタブへ) / shrink (より低いタブへ) **両方向** で追従させ、
        // clip も余白も出さない。
        let needsSnap = abs(window.frame.width - fixedWidth) > 1
            || abs(contentView.frame.height - fittedHeight) > 1
        if needsSnap {
            window.setContentSize(NSSize(width: fixedWidth, height: fittedHeight))
        }
    }

    /// SwiftUI Form (.grouped) は内部に NSScrollView を持つので、再帰的に探して
    /// documentView の真サイズを取得する。NSHostingView / NSStackView 等を経由しても辿れるよう
    /// 全 subview 再帰で探索。
    private static func findScrollViewDocumentHeight(in view: NSView) -> CGFloat? {
        if let scrollView = view as? NSScrollView, let document = scrollView.documentView {
            return document.frame.height
        }
        for sub in view.subviews {
            if let height = findScrollViewDocumentHeight(in: sub) {
                return height
            }
        }
        return nil
    }

    /// SwiftUI が設定した delegate を proxy しつつ、`windowWillResize` だけは自前で clamp。
    final class ResizeDelegate: NSObject, NSWindowDelegate {
        let fixedWidth: CGFloat
        let minHeight: CGFloat
        var maxHeight: CGFloat = 600
        weak var proxyTarget: NSWindowDelegate?

        init(fixedWidth: CGFloat, minHeight: CGFloat) {
            self.fixedWidth = fixedWidth
            self.minHeight = minHeight
        }

        // 自前で実装している method はここで処理、それ以外は forwardingTarget に転送する。
        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            // frameSize は window frame size (titlebar 込み)。content height = frame.height - titlebar。
            let titleBarHeight = sender.frame.height - (sender.contentView?.frame.height ?? sender.frame.height)
            let safeTitleBar = max(titleBarHeight, 0)
            let proposedContentHeight = frameSize.height - safeTitleBar
            let clampedContentHeight = min(max(proposedContentHeight, minHeight), maxHeight)
            return NSSize(width: fixedWidth, height: clampedContentHeight + safeTitleBar)
        }

        // proxyTarget が実装している method を responds(to:) / forwardingTarget(for:) で転送。
        override func responds(to aSelector: Selector!) -> Bool {
            if super.responds(to: aSelector) { return true }
            return proxyTarget?.responds(to: aSelector) ?? false
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            return proxyTarget
        }
    }
}
