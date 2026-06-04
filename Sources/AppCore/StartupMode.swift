// SPDX-License-Identifier: MIT
import Foundation

public enum StartupMode: String, CaseIterable, Sendable {
    case titleScreen = "title"
    case lastOpened = "lastOpened"
    case fixedLibrary = "fixed"

    public static let `default`: StartupMode = .lastOpened

    public static let userDefaultsKey = "stacknest.startupMode"
    public static let fixedLibraryURLKey = "stacknest.fixedLibraryURL"
}
