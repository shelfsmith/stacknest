// SPDX-License-Identifier: MIT
// StackNest archive (ZIP/RAR/7z) reading layer.

import Foundation

public enum ArchiveFormat: String, Sendable {
    case zip
    case rar
    case sevenZ = "7z"
}

public enum ArchiveAdapter {
    public static let moduleVersion = "0.1.0"
    /// Phase 2.2 で zip/rar/sevenZ を順次追加する。
    public static let supportedFormats: [ArchiveFormat] = []
}
