// SPDX-License-Identifier: MIT
import Foundation

/// キャプチャしたキー入力の正規化表現。文字割当（配列非依存）か chord 割当（keyCode+修飾）。
public enum CapturedBinding: Hashable, Sendable {
    case character(String)
    case chord(KeyChord)
}

/// keyDown の生情報を CapturedBinding へ分類する（AppKit 非依存・純関数）。
public enum KeyCaptureClassifier {
    /// - Parameters:
    ///   - keyCode: NSEvent.keyCode
    ///   - modifiers: NSEvent.modifierFlags.rawValue（呼び出し側で & relevantMask 済でも可）
    ///   - characters: NSEvent.charactersIgnoringModifiers（shift は適用済の文字）
    public static func classify(keyCode: UInt16, modifiers: UInt, characters: String?) -> CapturedBinding {
        let mods = modifiers & KeyChord.relevantMask
        let hasCmdCtrlOpt = (mods & (KeyChord.command | KeyChord.control | KeyChord.option)) != 0
        if !hasCmdCtrlOpt, let c = characters, isPrintableSingle(c) {
            return .character(c)
        }
        return .chord(KeyChord(keyCode: keyCode, modifiers: mods))
    }

    /// 1 文字かつ空白/制御文字でない（= 文字割当に使える）か。
    private static func isPrintableSingle(_ s: String) -> Bool {
        guard s.count == 1, let scalar = s.unicodeScalars.first else { return false }
        if scalar.properties.isWhitespace { return false }
        if scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value < 0xA0) { return false }
        return true
    }
}
