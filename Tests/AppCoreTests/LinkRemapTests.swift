// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("LinkRemap — group + prefix remap")
struct LinkRemapTests {
    @Test func groupByParentDirectory() {
        let paths = ["/A/x/1.zip", "/A/x/2.zip", "/A/y/3.zip"]
        let groups = LinkRemap.groupByParentDirectory(paths)
        #expect(groups.count == 2)
        let dirs = Set(groups.map(\.directory))
        #expect(dirs == ["/A/x", "/A/y"])
        let x = groups.first { $0.directory == "/A/x" }!
        #expect(x.paths == ["/A/x/1.zip", "/A/x/2.zip"])
    }
    @Test func remapNestedPreservesRelative() {
        let paths = ["/Vol/Old/manga/a/1.zip", "/Vol/Old/manga/b/2.zip"]
        let r = LinkRemap.remap(paths: paths, oldDir: "/Vol/Old/manga", newDir: "/Vol/New/manga")
        #expect(r.count == 2)
        #expect(r.contains { $0.old == "/Vol/Old/manga/a/1.zip" && $0.new == "/Vol/New/manga/a/1.zip" })
        #expect(r.contains { $0.old == "/Vol/Old/manga/b/2.zip" && $0.new == "/Vol/New/manga/b/2.zip" })
    }
    @Test func remapExcludesNonMatching() {
        let paths = ["/A/x/1.zip", "/B/y/2.zip"]
        let r = LinkRemap.remap(paths: paths, oldDir: "/A/x", newDir: "/Z")
        #expect(r.map(\.old) == ["/A/x/1.zip"])
        #expect(r[0].new == "/Z/1.zip")
    }
    @Test func remapRespectsComponentBoundary() {
        // "/a/b" must NOT match "/a/bc/..."
        let paths = ["/a/bc/1.zip"]
        let r = LinkRemap.remap(paths: paths, oldDir: "/a/b", newDir: "/z")
        #expect(r.isEmpty)
    }
    @Test func remapDirItself() {
        let r = LinkRemap.remap(paths: ["/a/b/1.zip"], oldDir: "/a/b", newDir: "/x/y")
        #expect(r.count == 1)
        #expect(r[0].new == "/x/y/1.zip")
    }
    @Test func remapPreservesAbsoluteLeadingSlash() {
        let r = LinkRemap.remap(paths: ["/a/b/1.zip"], oldDir: "/a/b", newDir: "/Volumes/New")
        #expect(r[0].new == "/Volumes/New/1.zip")
    }
}
