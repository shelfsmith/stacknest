// SPDX-License-Identifier: MIT
import Testing
import Foundation
import AppKit
@testable import AppCore

@Suite("CoverSource & external cover")
struct CoverSourceTests {
    @Test func sentinelDetection() {
        #expect(CoverSource.externalSentinel == "@external")
        #expect(CoverSource.isExternal("@external"))
        #expect(!CoverSource.isExternal(nil))
        #expect(!CoverSource.isExternal("page001.jpg"))
    }

    @Test func regenerateFromImageDataWritesThumbnail() throws {
        // 32x32 の赤 JPEG を作る
        let img = NSImage(size: NSSize(width: 32, height: 32))
        img.lockFocus(); NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 32, height: 32)); img.unlockFocus()
        let tiff = img.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        let jpeg = rep.representation(using: .jpeg, properties: [:])!

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try CoverRefresher.regenerateFromImageData(bookID: 7, imageData: jpeg, thumbnailsDirURL: dir)
        let out = dir.appendingPathComponent("7/thumbnail.jpg")
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect((try Data(contentsOf: out)).count > 0)
    }
}
