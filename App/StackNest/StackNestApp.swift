// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import ObjectiveC
import os
import RemoteClient
import SwiftUI
import UniformTypeIdentifiers

// C-④a: 庫ウィンドウに bundleURL を関連付ける。NSWindow.willCloseNotification のグローバル観測で
// 「閉じられた窓が庫かどうか」を判定し open-set から削除するために使う（SwiftUI の onDisappear は
// WindowGroup で不確実だが willClose は手動クローズで確実に発火・⌘Q 終了時は非発火＝計測で確認済み）。
private nonisolated(unsafe) var stacknestBundleURLKey: UInt8 = 0
extension NSWindow {
    var stacknestBundleURL: URL? {
        get { objc_getAssociatedObject(self, &stacknestBundleURLKey) as? URL }
        set { objc_setAssociatedObject(self, &stacknestBundleURLKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// #7 (Codex High): リモート庫ウィンドウにも state を関連付ける。resume（⌘⇧O）の
// already-open 判定は「その庫の窓が実際に開いているか」に依存するため、閉鎖検知は
// SwiftUI の onDisappear（WindowGroup では不確実）ではなく、庫ウィンドウと同じ
// NSWindow.willCloseNotification のグローバル観測を主経路にする。
private nonisolated(unsafe) var stacknestRemoteStateKey: UInt8 = 0
extension NSWindow {
    var stacknestRemoteState: RemoteLibraryState? {
        get { objc_getAssociatedObject(self, &stacknestRemoteStateKey) as? RemoteLibraryState }
        set { objc_setAssociatedObject(self, &stacknestRemoteStateKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

// MARK: - WindowBridge
/// Singleton that bridges AppDelegate's `application(_:open:)` call (which fires before
/// SwiftUI scenes mount) with SwiftUI's `OpenWindowAction` environment (which is available
/// only after scenes mount). Ensures accurate `hasLaunchURL` state and allows conditional
/// Title window spawn via `.defaultLaunchBehavior(.suppressed)`.
@MainActor
final class WindowBridge: ObservableObject {
    static let shared = WindowBridge()
    var openWindowAction: OpenWindowAction?
}

// MARK: - FocusedValue for AppState
/// Enables window-specific menu commands to access the focused window's AppState.
private struct FocusedAppStateKey: FocusedValueKey {
    typealias Value = AppState
}

extension FocusedValues {
    var appState: AppState? {
        get { self[FocusedAppStateKey.self] }
        set { self[FocusedAppStateKey.self] = newValue }
    }
}

// MARK: - FocusedValue for RemoteLibraryState
// G12b-3c Task 9: appState と同じ仕組みで、フォーカス中リモートウィンドウの
// RemoteLibraryState をメニューコマンド（Edit > 取り消す/やり直す）から参照できるようにする。
private struct FocusedRemoteStateKey: FocusedValueKey {
    typealias Value = RemoteLibraryState
}

extension FocusedValues {
    var remoteState: RemoteLibraryState? {
        get { self[FocusedRemoteStateKey.self] }
        set { self[FocusedRemoteStateKey.self] = newValue }
    }
}

@main
struct StackNestApp: App {
    @NSApplicationDelegateAdaptor(StackNestAppDelegate.self) var appDelegate

    var body: some Scene {
        // Hidden bridge window — always spawns at launch, captures openWindow, decides Title spawn.
        // Declared FIRST so it gets initial spawn priority before other scenes.
        Window("Bridge", id: "_bridge") {
            BridgeContent()
        }
        .windowResizability(.contentSize)
        .windowStyle(.plain)     // borderless to minimize chrome
        .commandsRemoved()        // hide from menu

        // Title Screen — DEFAULT INITIAL SPAWN SUPPRESSED via .defaultLaunchBehavior(.suppressed).
        // Only opened when no launch URL is present (decided by BridgeContent.onAppear).
        WindowGroup(id: "title") {
            TitleScreenView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        // Library windows — URL-bound, one per bundle
        WindowGroup(for: URL.self) { $bundleURL in
            if let url = bundleURL {
                LibraryWindowContainer(bundleURL: url)
            }
        }
        .handlesExternalEvents(matching: Set(["library"]))

        // Phase 4.2b-1: リモートライブラリウィンドウ — RemoteLibraryRef-bound。
        WindowGroup(for: RemoteLibraryRef.self) { $ref in
            if let ref {
                RemoteLibraryWindowContainer(ref: ref)
            }
        }
        .commands {
            FileCommands(openWindow: openWindow)
            WindowCommands()
            ShareCommands(openWindow: openWindow)
            // macOS Sonoma+ の Settings scene は system-managed window で SwiftUI の
            // .windowResizability や .frame が一部しか効かない。横幅固定 + 縦のみ resize
            // をきちんと制御するために自前 Window scene 化し、⌘, は .appSettings の
            // command group を置き換えて hook する。
            CommandGroup(replacing: .appSettings) {
                Button("StackNest 設定…") {
                    openWindow(id: "settings")
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // About パネル: 独自ブランド + Stackroom 非関連を明示（docs/02_constraints.md 整合）。
            CommandGroup(replacing: .appInfo) {
                Button("StackNest について") {
                    Self.showAboutPanel()
                }
            }
            // Help メニュー: アプリ内ヘルプページ（Window id "help"）を開く。
            CommandGroup(replacing: .help) {
                Button("StackNest ヘルプ") {
                    openWindow(id: "help")
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }

        // 設定 window — Settings scene の代替。
        // shared singleton を参照することで Settings での変更が LibraryWindow 側の
        // HelperLauncher にも即時反映される (= app 再起動不要)。
        Window("StackNest 設定", id: "settings") {
            SettingsView(settings: .shared)
        }
        .windowResizability(.contentMinSize)  // AppKit min/max を尊重しつつ縦方向のみ user resize 可能にする
        // 4.2f: サーバ設定ウィンドウ（"sharing-settings"）と同じ初期位置（横中央・縦上寄り 0.2）で開く。
        .defaultPosition(UnitPoint(x: 0.5, y: 0.2))
        .defaultLaunchBehavior(.suppressed)   // 起動時は開かず、⌘, からのみ開く
        .commandsRemoved()                    // Window menu に出さない
        .restorationBehavior(.disabled)       // 過去 session の window size を復元しない (= 毎回 content size で開く)

        // 初回起動ウィザード — Bridge / 設定からのみ openWindow(id:"wizard")。
        Window("はじめに", id: "wizard") {
            FirstRunWizardView(settings: .shared)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
        .restorationBehavior(.disabled)

        // アプリ内ヘルプ — Help メニュー(⌘?)からのみ openWindow(id:"help")。
        Window("StackNest ヘルプ", id: "help") {
            HelpView()
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
        .restorationBehavior(.disabled)

        // Phase 4.2b-1 fixup v1: リモートブラウザ（接続）ウィンドウ — File メニュー / Title から openWindow(id:"connect")。
        // タイトルウィンドウを開かずに接続フローを完結する（A1）。4.2c-3 (A5-2): タイトルを「リモートブラウザ」に統一（旧「リモートビューア」）。
        Window("リモートブラウザ", id: "connect") {
            RemoteConnectFlowView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
        .restorationBehavior(.disabled)

        // Phase 4.2b-2 Task 5: オフラインビューア（ダウンロード済み）ウィンドウ。
        // File メニュー / Title から openWindow(id:"offline")。サーバ接続なしで動作する。
        // 4.2c-3 (A5-2 / v4 自由記載): ウィンドウタイトルは「StackNest Remote Offline」に統一。
        Window("StackNest Remote Offline", id: "offline") {
            OfflineLibraryView()
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
        .restorationBehavior(.disabled)

        // Phase 4.2c-2: 共有設定ウィンドウ — 「共有」メニュー / openWindow(id:"sharing-settings")。
        // Settings の旧「共有」タブを独立ウィンドウへ移設した（重複排除）。
        Window("サーバ設定", id: "sharing-settings") {
            SharingSettingsView()
        }
        .windowResizability(.contentMinSize)
        // 4.2c-6a (smoke v3/v4 自由記載): 共有 ON で内容が下方向に広がるため、中央だと画面下に
        // はみ出る。上 1/3 付近に配置して下方向の拡張余地を確保しつつ、メニューバー直下に
        // 張り付く違和感を避ける（v4: .top → 上 1/3）。
        .defaultPosition(UnitPoint(x: 0.5, y: 0.2))
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()
        .restorationBehavior(.disabled)
    }

    @Environment(\.openWindow) private var openWindow

    /// 標準 About パネルを表示する。
    /// アプリ名・アイコン・バージョン（CFBundleShortVersionString / CFBundleVersion）・
    /// コピーライト（NSHumanReadableCopyright）はバンドルから自動表示される。
    @MainActor
    static func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }
}

// MARK: - BridgeContent

/// The view content of the hidden bridge window.
/// Captures the OpenWindowAction environment and decides whether to open the Title window
/// based on `AppDelegate.hasLaunchURL`.
struct BridgeContent: View {
    static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "BridgeContent")

    @Environment(\.openWindow) private var openWindow
    @State private var window: NSWindow?

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .background(
                WindowAccessor { window in
                    self.window = window
                    // Make this window invisible immediately
                    window.alphaValue = 0
                    window.setFrame(NSRect(x: -100000, y: -100000, width: 1, height: 1), display: false)
                    window.orderOut(nil)
                }
            )
            .onAppear {
                // Capture openWindow into shared bridge
                WindowBridge.shared.openWindowAction = openWindow

                // Bridge is the canonical URL handler — always register, regardless of launch path.
                // This guarantees pendingURLs flush even when Title is suppressed.
                URLOpener.shared.register { url in
                    Self.logger.info("BridgeContent handler: openWindow(value:) for \(url.path)")
                    openWindow(value: url)
                }

                // Wait briefly for application(_:open:) to fire — it may arrive AFTER scene mount.
                // Plain launch → no URL arrives, fall through and open based on StartupMode.
                // URL launch → hasLaunchURL flips true within milliseconds, skip Title.
                Task { @MainActor in
                    // App ユニットテストではライブラリを一切復元しない。テストホストは
                    // アプリ本体なので、復元経路のモーダル（競合検知・復元失敗）が出ると
                    // 閉じる者がおらずテストが永久に停止する（AppEnvironment を参照）。
                    if AppEnvironment.isRunningUnitTests {
                        Self.logger.info("BridgeContent: running under XCTest → skip startup restore")
                        return
                    }
                    try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms grace period
                    if StackNestAppDelegate.hasLaunchURL {
                        Self.logger.info("BridgeContent: launch URL detected → skip Title")
                        return
                    }
                    // Phase 2.6c: 初回起動ウィザード。StartupMode より優先。
                    // 既存ユーザ（lastOpened 履歴あり）は対象外（フラグを立てて従来フローへ）。
                    if !AppPreferences.hasCompletedFirstRunWizard {
                        if UserDefaultsKeys.lastOpenedBundleURL() != nil {
                            AppPreferences.hasCompletedFirstRunWizard = true
                        } else {
                            Self.logger.info("BridgeContent: first run → openWindow(wizard)")
                            openWindow(id: "wizard")
                            return
                        }
                    }
                    let modeRaw = UserDefaults.standard.string(forKey: StartupMode.userDefaultsKey)
                        ?? StartupMode.default.rawValue
                    let mode = StartupMode(rawValue: modeRaw) ?? .default
                    switch mode {
                    case .titleScreen:
                        Self.logger.info("BridgeContent: startup=title → openWindow(title)")
                        openWindow(id: "title")
                    case .lastOpened:
                        // C-④a: 前回終了時に開いていた庫の集合があれば全復元。無ければ recency 先頭 1 件（従来互換）。
                        // failedToRestore は「開く意図があったのに全滅」＝アラート対象（意図的に空なら false）。
                        let restore = StartupRestore.plan(
                            openSet: UserDefaultsKeys.openLibraryBundleURLs(),
                            recencyFirst: UserDefaultsKeys.lastOpenedBundleURL(),
                            exists: { (try? LibraryBundle(url: $0).validate()) != nil }
                        )
                        if restore.urls.isEmpty {
                            Self.logger.info("BridgeContent: startup=lastOpened, none to restore → Title (failed=\(restore.failedToRestore))")
                            openWindow(id: "title")
                            if restore.failedToRestore {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    let alert = NSAlert()
                                    alert.messageText = "前回のライブラリが見つかりません"
                                    alert.informativeText = "タイトル画面から再度開いてください。"
                                    alert.runModal()
                                }
                            }
                        } else {
                            Self.logger.info("BridgeContent: startup=lastOpened → restoring \(restore.urls.count) libraries")
                            for url in restore.urls {
                                openWindow(value: url)
                            }
                        }
                    case .fixedLibrary:
                        let urlStr = UserDefaults.standard.string(forKey: StartupMode.fixedLibraryURLKey) ?? ""
                        if let url = URL(string: urlStr), (try? LibraryBundle(url: url).validate()) != nil {
                            Self.logger.info("BridgeContent: startup=fixed → openWindow(\(url.path))")
                            openWindow(value: url)
                        } else {
                            Self.logger.info("BridgeContent: startup=fixed, no/invalid URL → Title")
                            openWindow(id: "title")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                let alert = NSAlert()
                                alert.messageText = "指定ライブラリが見つかりません"
                                alert.informativeText = "Settings で再設定してください。"
                                alert.runModal()
                            }
                        }
                    }

                    // C-④a: 起動時に共有を自動開始（ライブラリ復元後・silent）。
                    // 配信は「開いている庫」依存のため switch(復元)後に発火する。
                    if ServerPreferences.autoStartSharingOnLaunch() {
                        Self.logger.info("BridgeContent: autoStartSharingOnLaunch → ServerController.start()")
                        ServerController.shared.start()
                    }
                }
            }
    }
}

// MARK: - WindowFrameObserver

/// Manages NSWindow frame persistence for LibraryWindowContainer.
/// Restores the saved frame on first window appearance and saves changes on resize/move.
@MainActor
private final class WindowFrameObserver: NSObject {
    private weak var window: NSWindow?
    private var settingsResolver: (() -> LibrarySettings?)?
    private var resizeObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?

    func setupFrameTracking(window: NSWindow, settingsResolver: @escaping () -> LibrarySettings?) {
        self.window = window
        self.settingsResolver = settingsResolver

        // Restore frame from settings
        if let settings = settingsResolver(), let frame = settings.windowFrame {
            let rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            window.setFrame(rect, display: true)
        }

        // Install observers for frame changes
        let center = NotificationCenter.default
        resizeObserver = center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveCurrentFrame()
            }
        }
        moveObserver = center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveCurrentFrame()
            }
        }
    }

    private func saveCurrentFrame() {
        guard let window = window, let settings = settingsResolver?() else { return }
        let f = window.frame
        settings.windowFrame = WindowFrame(
            x: Double(f.origin.x),
            y: Double(f.origin.y),
            width: Double(f.size.width),
            height: Double(f.size.height)
        )
    }

    @MainActor
    deinit {
        let center = NotificationCenter.default
        if let obs = resizeObserver {
            center.removeObserver(obs)
        }
        if let obs = moveObserver {
            center.removeObserver(obs)
        }
    }
}

// MARK: - LibraryWindowContainer

/// Container for a library window bound to a specific bundle URL.
/// Holds AppState, opens the bundle on first appearance, and registers the window
/// in OpenLibraryRegistry to prevent duplicate opens.
struct LibraryWindowContainer: View {
    let bundleURL: URL?
    @State private var appState: AppState?
    @State private var error: Error?
    @State private var hasLoaded = false
    @State private var frameObserver: WindowFrameObserver?
    /// Q3-2-v3: sheet 表示中は NSApp.keyWindow が sheet panel を指すため、
    /// host window への直接参照を保持して cancel 時に確実に close する。
    @State private var hostWindow: NSWindow?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        contentView
            .background(
                WindowAccessor { window in
                    // Q3-2-v3: Capture host window reference for reliable cancel dismissal.
                    if self.hostWindow == nil {
                        self.hostWindow = window
                    }
                    // C-④a: この庫ウィンドウの bundleURL を NSWindow に関連付ける
                    // （グローバルな willCloseNotification 観測が「閉じた窓＝庫」を識別するため）。
                    window.stacknestBundleURL = bundleURL
                    // Setup frame observer and trigger deferred restoration after settings load
                    let observer = WindowFrameObserver()
                    self.frameObserver = observer
                    Task { @MainActor in
                        // Wait for openBundle to populate librarySettings (up to 50 attempts × 50ms = 2.5s)
                        var attempts = 0
                        while appState?.librarySettings == nil && attempts < 50 {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            attempts += 1
                        }
                        // Pass a closure resolver that always returns the CURRENT librarySettings
                        // of appState, so frame writes go to whichever bundle is active.
                        observer.setupFrameTracking(window: window) { [weak appState] in
                            appState?.librarySettings
                        }
                    }
                }
            )
            .onAppear {
                if !hasLoaded {
                    hasLoaded = true
                    Task {
                        await openBundleIfNeeded()
                    }
                }
            }
            .onChange(of: bundleURL) { oldURL, newURL in
                hostWindow?.stacknestBundleURL = newURL   // C-④a: 窓再利用時に関連付けを更新
                if let oldURL {
                    appState?.closeBundle()
                    // G25b-1r/G25c: 旧 AppState を残したまま openBundleIfNeeded() の await を待つと、
                    // その間だけ旧庫の状態で解錠シートの判定が走る。appState を nil にすると
                    // contentView は ProgressView に落ちるため、幽霊解錠シートは生じない。
                    // （G25b-1r では旧 @State 変数も併せて落としていたが、G25c で廃止したため不要になった。）
                    appState = nil
                    LibraryOpenLockManager.shared.release(bundleURL: oldURL)
                    OpenLibraryRegistry.shared.unregister(oldURL)
                    UserDefaultsKeys.removeOpenLibrary(oldURL)   // C-④a: 窓再利用時は旧庫を集合から外す
                }
                Task { await openBundleIfNeeded() }
            }
            .onDisappear {
                if let url = bundleURL {
                    appState?.closeBundle()
                    LibraryOpenLockManager.shared.release(bundleURL: url)
                    OpenLibraryRegistry.shared.unregister(url)
                }
            }
            .task {
                Logger(subsystem: "app.shelfsmith.stacknest", category: "LibraryContainer").info("LibraryContainer mounted, registering handler for \(bundleURL?.path ?? "nil")")
                URLOpener.shared.register { url in
                    openWindow(value: url)
                }
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if let appState = appState {
            // G25c: 庫を開いた時点で固定される @State ではなく、現在のロック状態から都度導出する。
            // これにより開いた後に施錠された場合（設定シート／CLI・MCP／共有サーバ経由）も追従する。
            if appState.needsUnlock {
                Color.clear
                    .sheet(isPresented: .constant(true)) {
                        let settings = appState.librarySettings
                        LibraryUnlockSheet(
                            bundleURL: bundleURL!,
                            bundleName: bundleURL?.deletingPathExtension().lastPathComponent ?? "Library",
                            salt: settings?.lockPasswordSalt ?? "",
                            hash: settings?.lockPasswordHash ?? "",
                            useBiometric: settings?.useBiometric ?? false,
                            armedHash: { BiometricArming.armedHash(for: settings) },
                            armThisMachine: { verifiedHash in
                                // G25c: 現在値ではなく**検証したハッシュ**でアームする。
                                BiometricArming.arm(settings, hash: verifiedHash)
                                // 2.6g 以前の plaintext Keychain item を除去（one-shot、no-throw）
                                if let url = bundleURL { LibraryLock.purgeLegacyKeychainItem(bundleURL: url) }
                            },
                            onUnlock: { verifiedHash in
                                // G25c: 記録するのは**実際に検証が通ったハッシュ**（現在値ではない）。
                                // 生体認証のプロンプト表示中に外部からパスワードが差し替えられた場合、
                                // 記録値と現在値が食い違い isUnlocked は false のままになる＝素通りしない。
                                appState.markUnlocked(hash: verifiedHash)
                                // G25b-1r: ⌘⇧O が積んだ保留 resume を解錠成功後に開く（1 回だけ）。
                                // isUnlocked を立てた直後はまだ解錠シートが表示中で、その最中に
                                // ビューア窓を開くとシート解除と競合しうる。同ファイルの onCancel が
                                // 同じ理由で main.async を使っているのに倣い、1 tick 遅らせる。
                                DispatchQueue.main.async {
                                    appState.consumePendingResume()
                                }
                            },
                            onCancel: {
                                if let url = bundleURL {
                                    LibraryOpenLockManager.shared.release(bundleURL: url)
                                    OpenLibraryRegistry.shared.unregister(url)
                                }
                                // Q3-2-v3: sheet 表示中は NSApp.keyWindow が sheet panel を指すため
                                // host window を直接 close する。これにより sheet 自動再 attach を防ぐ。
                                // hostWindow が nil の場合のみ keyWindow へフォールバック。
                                DispatchQueue.main.async {
                                    (hostWindow ?? NSApp.keyWindow)?.close()
                                }
                            },
                            // G23 (#8): 旧形式（生 SHA-256）のハッシュを PBKDF2 形式へ移行する。
                            // lockPasswordHash は didSet で DB へ永続化される。この代入は
                            // armThisMachine より前に走るため、再アーム時の armedHash も新形式になる。
                            onUpgradeHash: { verifiedAgainst, upgraded in
                                // G25c: DB 層の原子的 compare-and-set に委ねる（メモリ比較では
                                // 別プロセス／別 Mac による差し替えを検出できず、外部設定の新パスワードを
                                // 巻き戻してしまう）。戻り値は**実際に DB を更新したか**。
                                settings?.upgradeLockHash(verifiedAgainst: verifiedAgainst, to: upgraded) ?? false
                            }
                        )
                    }
            } else {
            NavigationSplitView {
                SidebarView(appState: appState)
                    .frame(minWidth: 200)
            } content: {
                LibraryBrowserView(appState: appState)
                    .frame(minWidth: 480)
                    .searchable(text: Bindable(appState).searchQuery, placement: .toolbar, prompt: "検索")
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Picker("", selection: Bindable(appState).viewMode) {
                                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                                Image(systemName: "list.bullet").tag(ViewMode.list)
                            }
                            .pickerStyle(.segmented)
                        }
                        if let settings = appState.librarySettings {
                            ToolbarItem(placement: .primaryAction) {
                                FilterToolbarButton(filter: Bindable(settings).filterState, settings: settings)
                            }
                            ToolbarItem(placement: .primaryAction) {
                                Picker("", selection: Bindable(settings).topPaneMode) {
                                    Image(systemName: "rectangle.split.3x1").tag("browse")
                                    Image(systemName: "tag").tag("stamp")
                                    Image(systemName: "eye.slash").tag("hidden")
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 120)
                                .help("上ペイン切替 (⌥⌘B)")
                            }
                        }
                        // 4.1b / smoke v2 修正⑨: このウィンドウのライブラリ配信状態インジケータ。
                        // ServerController.shared / LibrarySettings は @Observable なので
                        // isRunning・remoteSharingEnabled の変化で再描画される。
                        // - サーバ未起動 → 非表示（現状維持）
                        // - サーバ起動中 → アンテナ。ON=緑 / OFF=灰斜線。クリックでトグル。
                        // A8: ウィンドウ左上（StackNest 表記の右）に置くため .navigation に配置。
                        if ServerController.shared.isRunning, let settings = appState.librarySettings {
                            ToolbarItem(placement: .navigation) {
                                SharingIndicatorButton(settings: settings)
                            }
                        }
                    }
            } detail: {
                DetailPaneView(
                    books: appState.displayedSelectedBooks,
                    librarySettings: appState.librarySettings,
                    bundleURL: appState.bundleURL,
                    loader: appState.thumbnailLoader,
                    canEdit: true,
                    showCover: appState.showDetailCover,
                    onApplyPatch: { id, p in appState.applyPatch(bookID: id, patch: p, undoManager: appState.undoManager) },
                    onApplyPatchMulti: { ids, p in
                        do { _ = try appState.applyPatch(bookIDs: ids, patch: p, undoManager: appState.undoManager) }
                        catch { appState.error = .unexpected(error) }
                    },
                    onSetCover: { name, id in try await appState.setCoverImageName(name, for: id, undoManager: appState.undoManager) },
                    onClearCrop: { id in try? appState.database?.updateBookCoverCropRect(id: id, json: nil); try? appState.refreshDisplayedBooks() },
                    onSetCrop: { id, j in try? appState.database?.updateBookCoverCropRect(id: id, json: j); try? appState.refreshDisplayedBooks() },
                    onJump: { f, v in appState.jumpToFilterOrSearch(field: f, value: v) },
                    onError: { err in
                        appState.error = nil
                        DispatchQueue.main.async { appState.error = err }
                    },
                    onSetExternalCover: { data, crop, id in
                        try? await appState.setExternalCover(bookID: id, imageData: data, cropRect: crop, undoManager: appState.undoManager)
                    },
                    coverVersion: appState.coverVersionByBook[appState.displayedSelectedBooks.first?.id ?? -1] ?? 0,
                    // G21 #5: 右クリック「表紙を再生成」。既存の regenerateThumbnail(for:) を再利用する
                    // （AppState.swift・per-book purge+refresh 込みの既存経路。外部表紙は自前で保護する）。
                    onRegenerateCover: { id in
                        guard let book = appState.displayedBooks.first(where: { $0.id == id }) else { return }
                        Task { await appState.regenerateThumbnail(for: book) }
                    }
                )
                    .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 240)
            }
            // 4.2c-3 (A3): タイトルはツールバー中央(principal)ではなく、ウィンドウタイトル
            // （左・背景なし・プレーン）として「StackNest – 〈表示名〉」を表示する。
            .navigationTitle("StackNest – \(libraryDisplayName)")
            .frame(minWidth: 1024, minHeight: 600)
            .environment(appState)
            .focusedSceneValue(\.appState, appState)
            // 4.2c-9: メニューコマンドのルーティング用（ローカルターゲット）。
            .focusedSceneValue(\.browserCommandTarget, appState as (any BrowserCommandTarget)?)
            } // end else (isUnlocked)
        } else if let error = error {
            ErrorView(error: error)
        } else {
            ProgressView()
                .frame(minWidth: 400, minHeight: 300)
        }
    }

    /// 4.2c-3: ブラウザツールバー principal の大見出し用ライブラリ表示名。
    /// カスタム表示名（LibrarySettings.resolvedName）が設定されていればそれを、
    /// 未設定ならバンドル名（拡張子を除いたファイル名）を返す。
    private var libraryDisplayName: String {
        let fallback = bundleURL?.deletingPathExtension().lastPathComponent ?? ""
        return appState?.librarySettings?.resolvedName(fallback: fallback) ?? fallback
    }

    private func openBundleIfNeeded() async {
        guard let bundleURL = bundleURL else { return }

        // Check if this URL is already open in another window
        if !OpenLibraryRegistry.shared.register(bundleURL) {
            // Already open; close this window
            dismiss()
            return
        }

        // Phase 2.6d: cross-Mac lock. Acquire before opening the SQLite DB.
        switch LibraryOpenLockManager.shared.acquire(bundleURL: bundleURL) {
        case .acquired, .unprotected:
            break
        case .conflict(let info):
            if Self.confirmForceOpen(bundleName: bundleURL.deletingPathExtension().lastPathComponent, holder: info) {
                LibraryOpenLockManager.shared.forceAcquire(bundleURL: bundleURL)
            } else {
                OpenLibraryRegistry.shared.unregister(bundleURL)
                dismiss()
                return
            }
        }

        do {
            let state = AppState(bundleURL: bundleURL)
            try state.openBundle()
            // Phase 2.5f: 全 library open 経路の集約点。fixedLibrary 起動 /
            // Finder ダブルクリック / File menu / Title 等すべてここを通る。
            UserDefaultsKeys.appendLastOpenedBundleURL(bundleURL)
            UserDefaultsKeys.addOpenLibrary(bundleURL)   // C-④a: 開いている庫集合へ追加（willClose で削除）
            self.appState = state
            // G25b-1r: isUnlocked は「このセッションでパスワード検証に成功した」だけを表し、
            // 「施錠されていない」は含めない（＝庫を開いた時点では常に false）。
            // 未施錠を true で表すと、開いた後に施錠された場合（設定シート／CLI・MCP／共有サーバ経由）に
            // 「解錠していないのに解錠済み」になり、⌘⇧O がロックを迂回する。
            // G25c: 解錠シートの表示条件も AppState.needsUnlock から都度導出するため、
            // ここで表示用のフラグを別に持つ必要はない（施錠の有無は librarySettings が正）。
            state.markUnlocked(hash: nil)
        } catch {
            LibraryOpenLockManager.shared.release(bundleURL: bundleURL)
            OpenLibraryRegistry.shared.unregister(bundleURL)
            if case LibraryOpenError.cancelledByUser = error {
                dismiss()   // ユーザーが破損ダイアログで「閉じる/やめる」を選んだ。静かに閉じる。
            } else {
                self.error = error
            }
        }
    }

    /// Modal warning when the library is already locked by another Mac/process.
    /// Returns true if the user chose "force open".
    @MainActor
    static func confirmForceOpen(bundleName: String, holder: LibraryOpenLockInfo) -> Bool {
        // テスト実行中はモーダルを出さず、安全側の既定（＝開かない）で即答する。
        // 起動時復元は AppEnvironment の判定で既に抑止済みだが、テストが明示的に庫を
        // 開こうとした場合の二重の歯止め。
        if AppEnvironment.isRunningUnitTests { return false }
        let sameHost = holder.hostUUID == LibraryOpenLockManager.shared.currentHostUUIDString
        let location = sameHost ? "別のプロセス" : "別の Mac（\(holder.hostName)）"
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "「\(bundleName)」は\(location)で開かれています"
        alert.informativeText = "同時に開くとデータベースが破損する恐れがあります。通常は開かないことを強く推奨します。"
        alert.addButton(withTitle: "開かない")                 // default (return .alertFirstButtonReturn)
        alert.addButton(withTitle: "強制的に開く（危険）")
        return alert.runModal() == .alertSecondButtonReturn
    }
}

// MARK: - SharingIndicatorButton

/// smoke v2 修正⑨: サーバ起動中に表示するツールバーの配信状態インジケータ。
/// このウィンドウのライブラリ `remoteSharingEnabled` を反映し、クリックでトグルする。
/// LibrarySettings は @Observable なので toggle で即 UI 反映 + didSet で DB 永続。
/// （サーバ自体は既に起動中なのでサーバ操作は不要。）
private struct SharingIndicatorButton: View {
    @Bindable var settings: LibrarySettings

    var body: some View {
        let on = settings.remoteSharingEnabled
        Button {
            settings.remoteSharingEnabled.toggle()
        } label: {
            Image(systemName: on
                ? "antenna.radiowaves.left.and.right"
                : "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(on ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
        // 修正⑥: 他のツールバーボタン（FilterToolbarButton 等）と同じ円形背景にする。
        // それらは .buttonStyle を指定せず既定のツールバーボタンスタイルを使っているので、
        // ここも .buttonStyle(.plain) を外して既定（円形背景付き）に揃える。
        .help(on
            ? "このライブラリを配信中（クリックで停止）"
            : "このライブラリは非配信（クリックで配信）")
    }
}

// MARK: - FileCommands

/// File menu commands for creating/opening/importing libraries.
struct FileCommands: Commands {
    let openWindow: OpenWindowAction
    // 4.2c-9: 設定/削除系をアクティブウィンドウ（ローカル/リモート）でルーティング・無効化する。
    @FocusedValue(\.browserCommandTarget) private var target

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新しいライブラリ…") {
                LibraryActions.runSavePanelStandalone(defaultName: "Untitled.stacknest") { bundleURL in
                    Task {
                        do {
                            let finalURL = bundleURL.pathExtension == "stacknest" ? bundleURL : bundleURL.appendingPathExtension("stacknest")
                            _ = try LibraryBundleCreator.createEmpty(at: finalURL)
                            UserDefaultsKeys.setDefaultLibraryParentURL(finalURL.deletingLastPathComponent())
                            // appendLastOpenedBundleURL は LibraryWindowContainer.openBundleIfNeeded に集約済 (Phase 2.5f)
                            openWindow(value: finalURL)
                        } catch {
                            NSAlert.presentError(error, title: "ライブラリを作成できませんでした")
                        }
                    }
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("最後に開いたページを開く") {
                Task { await ResumeLastReadCoordinator.resume(openWindow: openWindow) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("ライブラリを開く…") {
                LibraryActions.runOpenPanelStandalone { bundleURL in
                    Task {
                        do {
                            let bundle = LibraryBundle(url: bundleURL)
                            try bundle.validate()
                            // appendLastOpenedBundleURL は LibraryWindowContainer.openBundleIfNeeded に集約済 (Phase 2.5f)
                            openWindow(value: bundleURL)
                        } catch {
                            NSAlert.presentError(error, title: "ライブラリを開けませんでした")
                        }
                    }
                }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Stackroom Library から取り込む…") {
                LibraryActions.runXMLOpenPanelStandalone { xmlURL in
                    Task {
                        do {
                            let defaultName = xmlURL.deletingPathExtension().lastPathComponent + ".stacknest"
                            LibraryActions.runSavePanelStandalone(defaultName: defaultName) { bundleURL in
                                Task {
                                    do {
                                        let finalURL = bundleURL.pathExtension == "stacknest" ? bundleURL : bundleURL.appendingPathExtension("stacknest")
                                        _ = try LibraryBundleCreator.createFromStackroomXML(
                                            xmlURL: xmlURL,
                                            into: finalURL
                                        )
                                        UserDefaultsKeys.setDefaultLibraryParentURL(finalURL.deletingLastPathComponent())
                                        // appendLastOpenedBundleURL は LibraryWindowContainer.openBundleIfNeeded に集約済 (Phase 2.5f)
                                        openWindow(value: finalURL)
                                    } catch {
                                        NSAlert.presentError(error, title: "ライブラリを取り込めませんでした")
                                    }
                                }
                            }
                        } catch {
                            NSAlert.presentError(error, title: "XML ファイルを選択できませんでした")
                        }
                    }
                }
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        CommandGroup(after: .newItem) {
            Divider()
            // Task 6: context menu の keyboardShortcut 表記を削除するため、
            // main menu に同一ショートカットを定義して動作を維持する。
            // 4.2c-9: ファイル実体が要る操作はリモートで無効化（canManageFiles=false）。
            Button("ファイル名を変更…") {
                NotificationCenter.default.post(name: .renameSelectedBooks, object: nil)
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!(target?.canManageLocalFiles ?? false))

            Button("ファイルを移動…") {
                NotificationCenter.default.post(name: .moveSelectedBooks, object: nil)
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!(target?.canManageLocalFiles ?? false))

            Button("リンク切れを検出…") {
                NotificationCenter.default.post(name: .detectBrokenLinks, object: nil)
            }
            .disabled(!(target?.canManageLocalFiles ?? false))

            // G12b-2 smoke: 「重複を検出…」は表示メニューではなく File メニューの
            // 「リンク切れを検出…」の下が適切（ユーザー要望）。gate はローカル/リモート共通の
            // canEditMeta（ローカル=true固定・リモート=state.canEdit）。
            Button("重複を検出…") {
                NotificationCenter.default.post(name: .openDuplicateScan, object: nil)
            }
            .disabled(!(target?.canEditMeta ?? false))

            Divider()
            Button("ライブラリから削除") {
                NotificationCenter.default.post(name: .stacknestDeleteFromLibraryRequest, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!(target?.canManageFiles ?? false))

            Button("ファイルをゴミ箱に移動…") {
                NotificationCenter.default.post(name: .stacknestMoveToTrashRequest, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(!(target?.canManageFiles ?? false))

            Divider()
            // 4.2c-9: 設定はアクティブに応じローカル/リモートのシートを開く。リモートは RW のみ（canEditMeta）。
            Button("このライブラリの設定…") { target?.openSettings() }
            .keyboardShortcut(",", modifiers: [.command, .shift])
            .disabled(!(target?.canEditMeta ?? false))
        }
    }
}

// MARK: - WindowCommands

/// Window-specific menu commands: view mode toggle, table column visibility,
/// rating/unread toggles. Bound to the focused library window's AppState via @FocusedValue.
struct WindowCommands: Commands {
    @FocusedValue(\.appState) private var appState
    // G12b-3c Task 9: フォーカス中がリモートウィンドウなら RemoteLibraryState.undo()/redo() を使う。
    @FocusedValue(\.remoteState) private var remoteState
    // 4.2c-9: 表示/上ペイン/レートはローカル/リモート共通の target 経由でルーティングする。
    @FocusedValue(\.browserCommandTarget) private var target

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("リスト/アイコン表示") { target?.toggleViewMode() }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(target == nil)
        }

        CommandGroup(after: .toolbar) {
            Button("上ペイン: ブラウズ / スタンプ / 隠す を切替") { target?.cycleTopPane() }
            .keyboardShortcut("b", modifiers: [.option, .command])
            .disabled(target == nil)
        }

        CommandGroup(after: .toolbar) {
            Menu("テーブル列") {
                // 4.2c-9: ローカル/リモートのアクティブウィンドウの settings で列トグル（リモートも対応）。
                if let settings = target?.librarySettingsForColumns {
                    ForEach(BookColumn.allCases.filter { !$0.alwaysVisible }, id: \.self) { col in
                        Toggle(settings.label(for: col), isOn: Binding(
                            get: { settings.listViewColumns.contains(col) },
                            set: { _ in settings.toggleColumn(col) }
                        ))
                    }
                }
            }
            .disabled(target?.librarySettingsForColumns == nil)
        }

        // Phase 2.7: 重複検出シートを開く。key window の LibraryBrowserView / RemoteLibraryView が通知を受ける。
        // G12b-2 Task 5: 従来は appState(ローカル専用 FocusedValue) で disabled 判定していたため、
        // リモートウィンドウがフロントの間は appState が常に nil となりメニューが恒久的に disabled
        // になっていた（RemoteLibraryView は \.appState を設定しない）。ローカル/リモート共通の
        // target(browserCommandTarget).canEditMeta に揃えた。G12b-2 smoke の要望で、メニュー項目は
        // 表示メニューから File メニュー（リンク切れを検出の下）へ移設済み（上記 .newItem グループ）。

        // Phase 2.5c spec a / 2.5c spec b v14-v15: Undo / Redo を AppState.undoManager にバインド。
        //
        // 旧実装は `NSApp.keyWindow?.firstResponder?.undoManager` を参照していたが、これは
        // AppKit responder chain 由来の standard undoManager で、SwiftUI `@Environment(\.undoManager)`
        // とは別 instance になることが diagnostic で確認済 (2026-05-23, action name "DIAG_UNDO_xxxxxxx"
        // が Edit menu に反映されず単に「取り消す」が出ていた)。結果として AppState.applyPatch /
        // setCoverImageName が SwiftUI 由来 undoManager に register していた undo step は
        // Edit menu の ⌘Z では一切 trigger されない、という分断状態だった。
        //
        // 構造的解決: AppState 自身が単一の UndoManager を所有し、すべての register/undo を
        // この instance に集約。Edit menu はここで AppState.undoManager に直接 bind することで
        // ⌘Z と register-side の undoManager が確実に一致する。
        //
        // v15 追加: `canUndo` / `canRedo` は KVO API で SwiftUI dependency tracking 非対応。
        // `appState.undoStateVersion` (Observable) を closure 内で read することで stack 変化
        // 検知 → menu の disabled state が register 直後にも反映される。
        // G12b-3c Task 9: フォーカス中がリモートウィンドウなら RemoteLibraryState.undo()/redo()
        // へルーティングする（\.remoteState が非 nil）。ローカルウィンドウがフォーカス中は
        // \.remoteState が nil のまま（RemoteLibraryView のみが .focusedSceneValue(\.remoteState,
        // ...) を設定するため）、従来どおり appState.undoManager にフォールバックする。
        CommandGroup(replacing: .undoRedo) {
            Button("取り消す") {
                if let remoteState {
                    Task { await remoteState.undo() }
                } else {
                    appState?.undoManager.undo()
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled({
                if let remoteState {
                    _ = remoteState.undoStateVersion  // dependency tracking
                    return !remoteState.canUndo
                }
                _ = appState?.undoStateVersion  // dependency tracking
                return !(appState?.undoManager.canUndo ?? false)
            }())

            Button("やり直す") {
                if let remoteState {
                    Task { await remoteState.redo() }
                } else {
                    appState?.undoManager.redo()
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled({
                if let remoteState {
                    _ = remoteState.undoStateVersion
                    return !remoteState.canRedo
                }
                _ = appState?.undoStateVersion
                return !(appState?.undoManager.canRedo ?? false)
            }())
        }

        // M2-2-v3: Edit menu の clipboard 系を完全置き換え。
        // 標準「すべてを選択」(⌘A) を削除して独自「すべての本を選択」に統一する。
        // Cut/Copy/Paste/Delete は sendAction で標準 responder chain の動作を再現する。
        CommandGroup(replacing: .pasteboard) {
            Button("カット") {
                NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("x", modifiers: .command)
            Button("コピー") {
                NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("c", modifiers: .command)
            Button("ペースト") {
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: .command)
            Button("削除") {
                NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil)
            }
            Divider()
            Button("すべてを選択") {
                // テキストフィールドにフォーカスがある場合はテキスト全選択、それ以外は本を全選択。
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder.responds(to: #selector(NSText.selectAll(_:))),
                   (responder is NSText || responder is NSTextView ||
                    (responder as? NSView)?.isKind(of: NSTextField.self) == true ||
                    String(describing: type(of: responder)).contains("TextField")) {
                    NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                } else if !NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) {
                    // 4.2c-3 (D2): リモート/オフライン/ローカルのリスト（NSTableView / SwiftUI List）は
                    // responder chain の selectAll: で全選択される。selectAll: を実装しない first
                    // responder（ローカル grid 等）の場合のみ、本モデル全選択を通知で依頼する。
                    NotificationCenter.default.post(name: .stacknestSelectAllRequest, object: nil)
                }
            }
            .keyboardShortcut("a", modifiers: .command)
        }

        CommandMenu("レート") {
            // 4.2c-9: レートは target 経由（リモートは R でも可＝共有評価・canRate）。
            Button("レートなし") { target?.setRating(0) }
                .keyboardShortcut("0", modifiers: .command).disabled(!(target?.canRate ?? false))
            Button("★") { target?.setRating(1) }
                .keyboardShortcut("1", modifiers: .command).disabled(!(target?.canRate ?? false))
            Button("★★") { target?.setRating(2) }
                .keyboardShortcut("2", modifiers: .command).disabled(!(target?.canRate ?? false))
            Button("★★★") { target?.setRating(3) }
                .keyboardShortcut("3", modifiers: .command).disabled(!(target?.canRate ?? false))
            Button("★★★★") { target?.setRating(4) }
                .keyboardShortcut("4", modifiers: .command).disabled(!(target?.canRate ?? false))
            Button("★★★★★") { target?.setRating(5) }
                .keyboardShortcut("5", modifiers: .command).disabled(!(target?.canRate ?? false))
            Divider()
            // 4.2c-9: 未読チェックも target 経由（リモートは R でも可＝共有閲覧状態・canMarkUnread）。
            Button("未読チェック") { target?.toggleUnread() }
                .keyboardShortcut("t", modifiers: .command).disabled(!(target?.canMarkUnread ?? false))
        }
    }
}

// MARK: - ErrorView

struct ErrorView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("ライブラリを開けませんでした")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(minWidth: 400, minHeight: 300)
    }
}

// MARK: - NSAlert Extension

extension NSAlert {
    /// Present an error alert to the user.
    static func presentError(
        _ error: Error?,
        title: String = "エラー",
        message: String? = nil
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title

        if let message = message {
            alert.informativeText = message
        } else if let error = error {
            alert.informativeText = error.localizedDescription
        } else {
            alert.informativeText = "不明なエラーが発生しました"
        }

        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - StackNestAppDelegate

@MainActor
final class StackNestAppDelegate: NSObject, NSApplicationDelegate {
    static let logger = Logger(subsystem: "app.shelfsmith.stacknest", category: "AppDelegate")

    /// Set to true when AppDelegate receives a launch URL via application(_:open:).
    /// BridgeContent.onAppear checks this to decide whether to suppress Title window spawn.
    static var hasLaunchURL = false
    /// C-④a: 終了処理中フラグ。終了時に窓が閉じても open-set から削除しない（開いていた庫を復元対象に残す）。
    static var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 4.2c-9 (#5): StackNest はウィンドウタブを使わないため標準タブバーを無効化する
        //（「表示 ▸ タブバーを表示／すべてのタブを表示」メニューを消す）。allowsAutomaticWindowTabbing
        // は NSWindow のクラスプロパティ。
        NSWindow.allowsAutomaticWindowTabbing = false
        // C-④a: 庫ウィンドウのクローズを確実に検知して open-set から削除する（増分維持）。
        // SwiftUI の onDisappear は WindowGroup で不確実だが、NSWindow.willCloseNotification は
        // 手動クローズで確実に発火する（計測で確認）。終了(⌘Q)時は発火しない＝開いていた庫は残る。
        // willCloseNotification は main で post されるため @objc @MainActor セレクタで受ける。
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
        // 4.2d-2: 127.0.0.1 ローカル制御エンドポイントを起動する（isRunning ガードで冪等）。
        LocalControlController.shared.startIfEnabled()
        // 4.2f: 同梱 CLI（Contents/Helpers/stacknest-cli）の絶対パスを記録（MCP の自動解決用）。
        // 同梱が存在するときだけ記録する。非バンドル起動（dev の swift run 等）では既存値を
        // 消さない（Release 版が記録したパスを dev 起動で破壊しないため）。
        let cliURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/stacknest-cli")
        if FileManager.default.fileExists(atPath: cliURL.path) {
            ServerPreferences.setCLIPath(cliURL.path)
        }
        // G3a: リモートキャッシュの起動時整合＋設定適用
        Task {
            await RemotePageCache.shared.setLimit(RemoteCacheSettings.limitBytes())
            await RemotePageCache.shared.setMaxAge(RemoteCacheSettings.maxAgeSeconds())
            await RemotePageCache.shared.reconcile()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Mark that we received a launch URL. This fires BEFORE BridgeContent.onAppear.
        Self.hasLaunchURL = true
        Self.logger.info("application(open:) urls=\(urls.map(\.path))")
        for url in urls where url.pathExtension == "stacknest" {
            Task { @MainActor in
                URLOpener.shared.enqueue(url)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Don't trust `flag` — the hidden Bridge window counts as visible.
        // Detect user-facing visible windows by filtering out the bridge.
        let userVisibleWindows = NSApp.windows.filter { window in
            guard window.isVisible else { return false }
            // Exclude the Bridge window (off-screen, alphaValue 0)
            if window.identifier?.rawValue == "_bridge" { return false }
            if window.alphaValue == 0 { return false }
            // Exclude windows positioned off-screen (Bridge is at -100000,-100000)
            if window.frame.origin.x < -50000 || window.frame.origin.y < -50000 { return false }
            return true
        }
        Self.logger.info("applicationShouldHandleReopen: flag=\(flag), userVisibleCount=\(userVisibleWindows.count), bridge=\(WindowBridge.shared.openWindowAction == nil ? "nil" : "set")")

        if userVisibleWindows.isEmpty {
            if let action = WindowBridge.shared.openWindowAction {
                Self.logger.info("Reopening Title via Bridge (user-facing windows: 0)")
                action(id: "title")
            } else {
                Self.logger.error("Reopen requested but openWindowAction is nil")
            }
            return false  // we handled it
        }
        return true  // there are user-facing windows; let macOS bring app forward
    }

    /// C-④a: 庫ウィンドウのクローズ（手動）を open-set から削除する（増分維持）。
    /// willCloseNotification は main で post されるため @MainActor セレクタで安全に受けられる。
    /// 終了に伴うクローズは `isTerminating` で除外し、開いていた庫を復元対象に残す。
    @objc private func handleWindowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        // #7 (Codex High): リモート庫ウィンドウの閉鎖は、終了中かどうかに関わらず必ず
        // registry から外して library token を破棄する（閉じた庫の resume が「認証済みの窓が
        // 開いている」と誤判定して施錠庫の本を解錠なしで開くのを防ぐ）。onDisappear は
        // 補助経路として残すが、確実なのはこちら。
        if let st = w.stacknestRemoteState {
            RemoteLibraryRegistry.shared.remove(st)
            st.libraryToken = nil
            w.stacknestRemoteState = nil
        }
        // G25b-1r: ローカル庫にも同じ保証を与える。⌘⇧O の解錠判定が isUnlocked を読むように
        // なったため、閉じた窓の AppState に isUnlocked=true が残ると「解錠済み」と誤判定して
        // 施錠庫の本を解錠なしで開けてしまう。上のリモート枝と同じく、終了中かどうかに
        // 関わらず必ず落とす（closeBundle() は onDisappear 依存で、WindowGroup では不確実）。
        // closeBundle() 全体をここで呼んではいけない（DB クローズと B22 バックアップ／
        // open-set 復元のセマンティクスを壊す）。落とすのは解錠状態と保留 resume だけ。
        // 照合は path で行う。ResumeLastReadCoordinator が AppState を探すときの規則
        //（`$0.bundleURL.path == bundlePath`）と必ず一致させること。URL 同値比較にすると、
        // 末尾スラッシュ等の表現差でここだけ空振りし、coordinator 側は拾える＝防御が抜ける。
        if let url = w.stacknestBundleURL {
            for st in AppState.activeInstances.allObjects where st.bundleURL.path == url.path {
                st.markUnlocked(hash: nil)
                st.pendingResumeBookID = nil
            }
        }
        // C-④a: 庫ウィンドウの open-set 削除は「手動クローズのみ」（終了時は復元対象に残す）。
        guard !Self.isTerminating, let url = w.stacknestBundleURL else { return }
        UserDefaultsKeys.removeOpenLibrary(url)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // C-④a: できるだけ早く終了フラグを立てる（終了に伴う窓クローズで open-set を削らないため）。
        // 注: 将来ここで .terminateCancel を返す分岐を足す場合は isTerminating を false に戻す経路が要る
        //（現状は常に .terminateNow なのでリセット不要）。
        Self.isTerminating = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // C-④a: 終了確定。以後の窓クローズ（終了に伴うもの）で open-set を削らない
        // （開いていた庫を次回 .lastOpened 復元対象に残す）。
        Self.isTerminating = true
        // B22: Cmd-Q では LibraryWindowContainer.onDisappear が確実に発火しないため、
        // 終了時にも開いている各 AppState のバックアップを走らせる（didBackupThisSession で二重実行防止）。
        for state in AppState.activeInstances.allObjects {
            state.backupOnCloseIfNeeded()
        }
        // 4.1b: 内蔵リモート共有サーバを graceful に停止する。
        ServerController.shared.stop()
        // 4.2d-2: 127.0.0.1 ローカル制御エンドポイントを停止する。
        LocalControlController.shared.stop()
        LibraryOpenLockManager.shared.releaseAll()
        // G17 T1: L2 リモートキャッシュの deferred atime を best-effort でフラッシュする。
        // fire-and-forget（プロセス終了と競合し得るため完了は保証されない）。
        Task { await RemotePageCache.shared.flush() }
    }
}


// MARK: - Notification Names

extension Notification.Name {
    static let openLibrarySettings = Notification.Name("stacknest.openLibrarySettings")
    static let renameSelectedBooks = Notification.Name("stacknest.renameSelectedBooks")
    // 4.2c-9: toggleTopPaneMode 通知は cycleTopPane()(BrowserCommandTarget) 化で廃止。
    static let moveSelectedBooks = Notification.Name("stacknest.moveSelectedBooks")
    /// M2-2: Grid view 時に Edit menu「すべてを選択」が responder chain に届かない問題を回避。
    /// CommandGroup から Notification 経由で LibraryBrowserView に全選択を依頼する。
    static let stacknestSelectAllRequest = Notification.Name("stacknest.selectAllRequest")
    /// Task 6: context menu の keyboardShortcut 表記削除対応。main menu から削除/ゴミ箱を操作するための通知。
    static let stacknestDeleteFromLibraryRequest = Notification.Name("stacknest.deleteFromLibraryRequest")
    static let stacknestMoveToTrashRequest = Notification.Name("stacknest.moveToTrashRequest")
    /// Phase 2.7: 重複検出シートを開く（WindowCommands の「重複を検出…」から post）。
    static let openDuplicateScan = Notification.Name("stacknest.openDuplicateScan")
    /// Phase 2.8: リンク切れ検出シートを開く（File menu の「リンク切れを検出…」から post）。
    static let detectBrokenLinks = Notification.Name("stacknest.detectBrokenLinks")
}

// MARK: - UTType Extension

extension UTType {
    /// The StackNest library bundle type: a package directory containing library.db and Thumbnails/.
    static let stackNestLibrary = UTType(
        exportedAs: "app.shelfsmith.stacknest.library",
        conformingTo: .package
    )
}

// MARK: - UserDefaultsKeys

enum UserDefaultsKeys {
    static let lastOpenedBundleURLsKey = "stacknest.lastOpenedBundleURLs"
    static let defaultLibraryParentURLKey = "stacknest.defaultLibraryParentURL"
    /// 前回終了時に開いていた庫の集合（recency 履歴とは別。C-④a 全復元用）。
    static let openLibraryBundleURLsKey = "stacknest.openLibraryBundleURLs"

    /// 現在開いている庫の集合を保存する。
    static func setOpenLibraryBundleURLs(_ urls: [URL]) {
        UserDefaults.standard.setValue(urls.map { $0.absoluteString }, forKey: openLibraryBundleURLsKey)
    }

    /// 前回終了時に開いていた庫の集合を取得する。
    /// nil = キー未書込（アップグレード直後/新規）。書込済なら（空配列含む）[URL]。
    static func openLibraryBundleURLs() -> [URL]? {
        guard let strings = UserDefaults.standard.array(forKey: openLibraryBundleURLsKey) as? [String] else { return nil }
        return strings.compactMap { URL(string: $0) }
    }

    /// C-④a: 庫ウィンドウを開いたとき集合に追加する（増分維持）。
    /// SwiftUI/AppKit の終了フックは信頼できないため、open で追加・`NSWindow.willCloseNotification`
    /// で削除して集合を常に「現在開いている窓」に一致させる（計測で willClose は手動クローズで
    /// 確実に発火・⌘Q 終了時には発火しないことを確認済み）。
    static func addOpenLibrary(_ url: URL) {
        var set = Set((openLibraryBundleURLs() ?? []).map { $0.standardizedFileURL })
        set.insert(url.standardizedFileURL)
        setOpenLibraryBundleURLs(Array(set))
    }

    /// C-④a: 庫ウィンドウを閉じたとき集合から削除する（増分維持）。
    static func removeOpenLibrary(_ url: URL) {
        var set = Set((openLibraryBundleURLs() ?? []).map { $0.standardizedFileURL })
        set.remove(url.standardizedFileURL)
        setOpenLibraryBundleURLs(Array(set))
    }

    /// Append a bundle URL to the list of recently opened libraries.
    /// Limits history to the 10 most recent entries.
    static func appendLastOpenedBundleURL(_ url: URL) {
        var urls = lastOpenedBundleURLs()
        urls.removeAll { $0 == url }  // Remove duplicate if present
        urls.insert(url, at: 0)       // Add to front
        urls = Array(urls.prefix(10)) // Keep last 10
        UserDefaults.standard.setValue(
            urls.map { $0.absoluteString },
            forKey: lastOpenedBundleURLsKey
        )
    }

    /// Retrieve the list of recently opened library bundle URLs (most recent first).
    static func lastOpenedBundleURLs() -> [URL] {
        guard let strings = UserDefaults.standard.array(
            forKey: lastOpenedBundleURLsKey
        ) as? [String] else {
            return []
        }
        return strings.compactMap { URL(string: $0) }
    }

    /// Retrieve the single most recent bundle URL, if any.
    static func lastOpenedBundleURL() -> URL? {
        return lastOpenedBundleURLs().first
    }

    /// Retrieve the default parent directory for saving/opening libraries.
    /// Falls back to home directory if not set.
    static func defaultLibraryParentURL() -> URL? {
        guard let string = UserDefaults.standard.string(
            forKey: defaultLibraryParentURLKey
        ) else {
            return nil
        }
        return URL(string: string)
    }

    /// Set the default parent directory for saving/opening libraries.
    static func setDefaultLibraryParentURL(_ url: URL) {
        UserDefaults.standard.setValue(
            url.absoluteString,
            forKey: defaultLibraryParentURLKey
        )
    }
}
