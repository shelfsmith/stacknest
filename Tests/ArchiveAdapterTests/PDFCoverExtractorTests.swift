// SPDX-License-Identifier: MIT
import Foundation
import AppKit
import PDFKit
import Testing
@testable import ArchiveAdapter

@Suite("G54-S4: PDF の表紙候補")
struct PDFCoverExtractorTests {
    /// ページ数を指定して、その場で PDF を 1 つ作る。既定は全ページ 32x32 の白紙画像
    /// （ページを区別する必要のないテスト向け）。`colors` を渡すとページごとに塗りつぶし色を変え、
    /// 「指定したページが本当に返っているか」を後段で画素から確かめられるようにする
    /// （レビュー指摘: 全ページ同色だと `extractsNamedPage` が「1 ページ目固定で返す」実装でも
    /// 通ってしまい、`fallsBackToFirstPage` と実質同じ主張しかできていなかった）。
    /// `colors.count < pages` の場合は末尾を白で埋める。
    ///
    /// **返り値には各ページの「実際に描かれた」中央画素の RGB も含める**（`pixelColors`）。
    /// `NSColor.red` 等の理論値（255,0,0）を期待値にすると、`lockFocus()` によるビットマップ描画と
    /// 色空間変換（実機確認では sRGB/広色域 → デバイス RGB の変換で `.red` が (239,78,47) 相当まで
    /// 動く）だけで大きくずれてしまい、閾値を緩めるとページ同士の区別ができなくなる。
    /// フィクスチャ作成時に**自前で描いた直後の画素**を ground truth にすれば、PDF 化・thumbnail
    /// 描画・PNG 再エンコードによるずれ（実機確認では概ね ±1〜2）だけを許容すればよくなる。
    ///
    /// `PDFPage()` の空ページは `write(to:)` が成立しなかったため、`BookImporterTests.swift`
    /// の `threePagePDF()`（G54-S4 Task 1 以前から存在）に倣い `PDFPage(image:)` で作る。
    private func makePDF(pages: Int, colors: [NSColor] = []) throws -> (url: URL, pixelColors: [(r: Int, g: Int, b: Int)]) {
        let doc = PDFDocument()
        var pixelColors: [(r: Int, g: Int, b: Int)] = []
        for i in 0..<pages {
            let color = i < colors.count ? colors[i] : .white
            let img = NSImage(size: NSSize(width: 32, height: 32))
            img.lockFocus()
            color.setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: 32, height: 32)).fill()
            img.unlockFocus()
            pixelColors.append(try centerPixelColor(of: img.tiffRepresentation ?? Data()))
            guard let page = PDFPage(image: img) else {
                Issue.record("PDFPage(image:) failed to build test fixture page")
                continue
            }
            doc.insert(page, at: i)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g54s4-\(UUID().uuidString).pdf")
        #expect(doc.write(to: url))
        return (url, pixelColors)
    }

    /// 画像データ（PNG/TIFF どちらも可）の中央画素の RGB（0...255）を読む。
    /// 既存テストに画素読み出しのヘルパが無かったため新設（`NSBitmapImageRep.colorAt` を使う）。
    private func centerPixelColor(of data: Data) throws -> (r: Int, g: Int, b: Int) {
        guard let rep = NSBitmapImageRep(data: data) else {
            Issue.record("failed to decode image data into NSBitmapImageRep")
            return (0, 0, 0)
        }
        let x = rep.pixelsWide / 2
        let y = rep.pixelsHigh / 2
        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            Issue.record("failed to read center pixel color")
            return (0, 0, 0)
        }
        return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    /// 許容誤差つきで色が近いかを見る（PDF 描画・PNG 再エンコードで完全一致しない前提。
    /// 実機確認では ground-truth 画素との差は概ね ±1〜2 だったが、余裕を見て 20 とする）。
    private func isClose(_ actual: (r: Int, g: Int, b: Int), to expected: (r: Int, g: Int, b: Int), tolerance: Int = 20) -> Bool {
        abs(actual.r - expected.r) <= tolerance
            && abs(actual.g - expected.g) <= tolerance
            && abs(actual.b - expected.b) <= tolerance
    }

    @Test("ページ数だけ候補が並び、名前はページ番号")
    func listsOnePerPage() async throws {
        let (url, _) = try makePDF(pages: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let listing = try await PDFCoverExtractor().listImageEntries(in: url)
        #expect(listing.names == ["1", "2", "3"])
        #expect(listing.truncated == false)
    }

    @Test("候補の数を数えられる")
    func countsPages() async throws {
        let (url, _) = try makePDF(pages: 5)
        defer { try? FileManager.default.removeItem(at: url) }
        let count = try await PDFCoverExtractor().countImageEntries(in: url)
        #expect(count.count == 5)
        #expect(count.truncated == false)
    }

    @Test("名前で指定したページが画像になる")
    func extractsNamedPage() async throws {
        // ページごとに色を変え、「2 ページ目を指定したら本当に 2 ページ目（緑）が返る」ことを
        // 画素で確かめる。全ページ同色だと 1 ページ目固定で返す実装でも通ってしまうため
        // （レビュー指摘）、`fallsBackToFirstPage` と区別がつくようにした。
        let (url, colors) = try makePDF(pages: 3, colors: [.red, .green, .blue])
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try await PDFCoverExtractor().extractCoverImage(from: url, preferredName: "2")
        #expect(!data.isEmpty)
        #expect(NSImage(data: data) != nil)
        let pixel = try centerPixelColor(of: data)
        #expect(isClose(pixel, to: colors[1]), "expected page 2 color \(colors[1]) but got \(pixel)")
        #expect(!isClose(pixel, to: colors[0]), "page 2 should not look like page 1 \(colors[0])")
    }

    @Test("名前が無い・範囲外・数でないときは 1 ページ目に落ちる", arguments: [nil, "0", "99", "abc", ""])
    func fallsBackToFirstPage(name: String?) async throws {
        // 1 ページ目（赤）だけを期待色にして、フォールバック先が本当に 1 ページ目であることを見る。
        let (url, colors) = try makePDF(pages: 3, colors: [.red, .green, .blue])
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try await PDFCoverExtractor().extractCoverImage(from: url, preferredName: name)
        #expect(!data.isEmpty)
        let pixel = try centerPixelColor(of: data)
        #expect(isClose(pixel, to: colors[0]), "expected fallback to page 1 color \(colors[0]) but got \(pixel)")
    }

    @Test("名前なしの取り出しは 1 ページ目")
    func extractsFirstPageWithoutName() async throws {
        let (url, _) = try makePDF(pages: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try await PDFCoverExtractor().extractCoverImage(from: url)
        #expect(!data.isEmpty)
    }

    @Test("開けない PDF は投げる")
    func throwsOnBrokenFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("g54s4-broken-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: (any Error).self) {
            _ = try await PDFCoverExtractor().listImageEntries(in: url)
        }
    }

    // `PDFDocument().write(to:)` は 0 ページの文書を渡しても素通しせず、Quartz が
    // 空文書を無効とみなして自動で白紙 1 ページ（Letter サイズ）を足してから書き出す
    // （実機確認: pageCount=0 → write → 再度開くと pageCount=1）。したがって
    // 「開けて pageCount==0」なフィクスチャは PDFKit 経由では作れない —
    // 手組みの `/Count 0` PDF も CoreGraphics が無効な文書として弾いて開けない
    // （実機確認: `PDFDocument(url:)` が nil を返す＝`throwsOnBrokenFile` と同じ経路）。
    // そのため「0 ページ要求」の実際の観測可能な挙動は「自動挿入された 1 ページを普通に扱う」
    // ことになる。実装側の `guard doc.pageCount > 0` は、この経路では踏めないが
    // 将来 PDFKit の挙動が変わった場合や他ツールが吐いた度外れな PDF に備えた防御として残す。
    @Test("0 ページを要求しても PDFKit が白紙 1 ページを自動で足すため、その 1 ページとして扱われる（落ちない）")
    func handlesEmptyDocument() async throws {
        let (url, _) = try makePDF(pages: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let listing = try await PDFCoverExtractor().listImageEntries(in: url)
        #expect(listing.names == ["1"])
        #expect(listing.truncated == false)
    }
}
