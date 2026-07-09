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
