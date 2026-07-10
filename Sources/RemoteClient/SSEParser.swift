// SPDX-License-Identifier: MIT
import Foundation
import LibraryServerAPI

/// SSE テキストストリームを行バッファリングして LiveEvent 列に復号する。
/// `event:` と `data:` を 1 フレーム（空行区切り）で対応付ける。`:` 始まりはコメント（無視）。
public struct SSEParser {
    private var buffer = ""
    private var currentEvent: String?
    private var currentData: String?

    public init() {}

    public mutating func consume(_ text: String) -> [LiveEvent] {
        buffer += text
        var events: [LiveEvent] = []
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if line.isEmpty {
                if let ev = currentEvent, let data = currentData,
                   let parsed = LiveEvent.decode(event: ev, data: data) {
                    events.append(parsed)
                }
                currentEvent = nil; currentData = nil
            } else if line.hasPrefix(":") {
                continue   // コメント（ハートビート）
            } else if line.hasPrefix("event:") {
                currentEvent = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                currentData = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            }
        }
        return events
    }
}

extension SSEParser {
    /// 生 SSE バイト列を復号し、確定した LiveEvent ごとに `body` を呼ぶ。
    ///
    /// **重要**: `URLSession.AsyncBytes.lines` は空行を落とすが、SSE は空行（"\n\n"）を
    /// フレーム区切りに使い、`SSEParser` はそれを見て初めて event を emit する。よって
    /// `.lines` は使えず、本メソッドが生バイトを「行末 '\n' 込み」で `consume` に流して
    /// 空行区切りを保持する（0x0A は UTF-8 継続バイトに現れないので行境界として安全）。
    static func forEachEvent<Bytes: AsyncSequence>(
        inRawBytes bytes: Bytes, _ body: (LiveEvent) -> Void
    ) async throws where Bytes.Element == UInt8 {
        var parser = SSEParser()
        var lineBuf = [UInt8]()
        for try await byte in bytes {
            lineBuf.append(byte)
            if byte == 0x0A {
                for ev in parser.consume(String(decoding: lineBuf, as: UTF8.self)) { body(ev) }
                lineBuf.removeAll(keepingCapacity: true)
            }
        }
    }
}
