// SPDX-License-Identifier: MIT
/// G48-2b: 画像本の判定。**全 spine 項目**が「画像 1 枚のページ」であること（1 つでもテキストがあれば Washi へ）。
public enum EPUBImageBookDetection {
    public static func isImageBook(simpleImagePaths: [String?]) -> Bool {
        !simpleImagePaths.isEmpty && simpleImagePaths.allSatisfy { $0 != nil }
    }
}
