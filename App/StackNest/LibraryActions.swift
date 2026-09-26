// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import UniformTypeIdentifiers

/// Phase 2.6c: ライブラリの 新規作成 / 開く / 取り込み アクション。
/// TitleScreenView と FirstRunWizardView が共有する。
/// NSSave/OpenPanel ヘルパ（`Self.runSavePanelStandalone` 等）を内部で使う。
/// `onOpen` には開くべき bundle URL、`onError` にはエラーとタイトルが渡る。
@MainActor
enum LibraryActions {
    static func createNew(
        defaultName: String = "Untitled.stacknest",
        onOpen: @escaping (URL) -> Void,
        onError: @escaping (Error?, String) -> Void
    ) {
        Self.runSavePanelStandalone(defaultName: defaultName) { bundleURL in
            Task {
                do {
                    let finalURL = bundleURL.pathExtension == "stacknest"
                        ? bundleURL : bundleURL.appendingPathExtension("stacknest")
                    _ = try LibraryBundleCreator.createEmpty(at: finalURL)
                    UserDefaultsKeys.setDefaultLibraryParentURL(finalURL.deletingLastPathComponent())
                    onOpen(finalURL)
                } catch {
                    onError(error, String(localized: "ライブラリを作成できませんでした"))
                }
            }
        }
    }

    static func openExisting(
        onOpen: @escaping (URL) -> Void,
        onError: @escaping (Error?, String) -> Void
    ) {
        Self.runOpenPanelStandalone { bundleURL in
            Task {
                do {
                    let bundle = LibraryBundle(url: bundleURL)
                    try bundle.validate()
                    onOpen(bundleURL)
                } catch {
                    onError(error, String(localized: "ライブラリを開けませんでした"))
                }
            }
        }
    }

    static func importFromXML(
        onOpen: @escaping (URL) -> Void,
        onError: @escaping (Error?, String) -> Void
    ) {
        // Hoisted out of the nested Task/do-catch below: some Xcode toolchain versions fail to
        // extract a `String(localized:)` call into the String Catalog when it sits in the outer
        // `catch` of a do-block that also contains a nested Task with its own `String(localized:)`
        // call (a doubly-nested-closure extraction quirk, confirmed via `Scripts/l10n-lint.py`).
        // Evaluating it unconditionally here (cheap: a table lookup) sidesteps that.
        let xmlSelectionFailedMessage = String(localized: "XML ファイルを選択できませんでした")
        Self.runXMLOpenPanelStandalone { xmlURL in
            Task {
                do {
                    let defaultName = xmlURL.deletingPathExtension().lastPathComponent + ".stacknest"
                    Self.runSavePanelStandalone(defaultName: defaultName) { bundleURL in
                        Task {
                            do {
                                let finalURL = bundleURL.pathExtension == "stacknest"
                                    ? bundleURL : bundleURL.appendingPathExtension("stacknest")
                                _ = try LibraryBundleCreator.createFromStackroomXML(
                                    xmlURL: xmlURL, into: finalURL)
                                UserDefaultsKeys.setDefaultLibraryParentURL(
                                    finalURL.deletingLastPathComponent())
                                onOpen(finalURL)
                            } catch {
                                onError(error, String(localized: "ライブラリを取り込めませんでした"))
                            }
                        }
                    }
                } catch {
                    onError(error, xmlSelectionFailedMessage)
                }
            }
        }
    }

    // MARK: - Standalone Panel Helpers

    /// Static helper to run NSSavePanel standalone (for FileCommands).
    static func runSavePanelStandalone(defaultName: String = "Untitled.stacknest", completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = String(localized: "新しいライブラリを作成")
        panel.message = String(localized: "新しい StackNest ライブラリの保存先を選んでください")
        panel.allowedContentTypes = [.stackNestLibrary]
        panel.nameFieldStringValue = defaultName
        panel.canCreateDirectories = true
        panel.directoryURL = UserDefaultsKeys.defaultLibraryParentURL()
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        let response = panel.runModal()
        if response == .OK, let url = panel.url {
            completion(url)
        }
    }

    /// Static helper to run NSOpenPanel for existing library (for FileCommands).
    static func runOpenPanelStandalone(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "ライブラリを開く")
        panel.message = String(localized: "StackNest ライブラリを選択してください")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.stackNestLibrary]
        panel.directoryURL = UserDefaultsKeys.defaultLibraryParentURL()
            ?? FileManager.default.homeDirectoryForCurrentUser

        let response = panel.runModal()
        if response == .OK, let url = panel.urls.first {
            completion(url)
        }
    }

    /// Static helper to run NSOpenPanel for Stackroom XML (for FileCommands).
    static func runXMLOpenPanelStandalone(completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Stackroom XML から取り込む")
        panel.message = String(localized: "Stackroom の library.xml ファイルを選択してください")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.xml]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        let response = panel.runModal()
        if response == .OK, let url = panel.urls.first {
            // Verify it looks like a Stackroom XML by checking the filename or basic structure
            if url.lastPathComponent.lowercased() == "library.xml" ||
               url.lastPathComponent.lowercased().contains("library") {
                completion(url)
            } else {
                NSAlert.presentError(
                    nil,
                    title: String(localized: "Stackroom ライブラリファイルが不正です"),
                    message: String(localized: "Stackroom ライブラリ内の 'library.xml' という名前のファイルを選択してください")
                )
            }
        }
    }
}
