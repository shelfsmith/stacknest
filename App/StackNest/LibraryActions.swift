// SPDX-License-Identifier: MIT
import AppCore
import AppKit
import LibraryStore
import StackroomFormat
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
                    onError(error, "Failed to create library")
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
                    onError(error, "ライブラリを開けませんでした")
                }
            }
        }
    }

    static func importFromXML(
        onOpen: @escaping (URL) -> Void,
        onError: @escaping (Error?, String) -> Void
    ) {
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
                                onError(error, "Failed to import library")
                            }
                        }
                    }
                } catch {
                    onError(error, "Failed to select XML file")
                }
            }
        }
    }

    // MARK: - Standalone Panel Helpers

    /// Static helper to run NSSavePanel standalone (for FileCommands).
    static func runSavePanelStandalone(defaultName: String = "Untitled.stacknest", completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Create New Library"
        panel.message = "Choose a location for your new StackNest library"
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
        panel.title = "Open Library"
        panel.message = "Select a StackNest library bundle"
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
        panel.title = "Import from Stackroom XML"
        panel.message = "Select a Stackroom library.xml file"
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
                    title: "Invalid Stackroom Library File",
                    message: "Please select a file named 'library.xml' from your Stackroom library"
                )
            }
        }
    }
}
