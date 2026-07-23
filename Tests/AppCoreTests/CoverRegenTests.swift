// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite struct CoverRegenTests {
    // classifyEntry
    @Test func nonExternalIsNotExternal() {
        #expect(CoverRegen.classifyEntry(wasExternal: false, externalThumbnailExists: false) == .notExternal)
        #expect(CoverRegen.classifyEntry(wasExternal: false, externalThumbnailExists: true) == .notExternal)
    }
    @Test func externalWithThumbnailIsPreserved() {
        #expect(CoverRegen.classifyEntry(wasExternal: true, externalThumbnailExists: true) == .preserveExternal)
    }
    @Test func externalWithoutThumbnailFallsBack() {
        #expect(CoverRegen.classifyEntry(wasExternal: true, externalThumbnailExists: false) == .fallbackToAuto)
    }

    // writeDecision — external race に負けるのが最優先、次に stale relink、どちらもなければ write
    @Test func writeWhenNoGuardTrips() {
        #expect(CoverRegen.writeDecision(liveIsExternal: false, liveThumbnailExists: false,
                                         snapshotPath: "/a", livePath: "/a") == .write)
    }
    @Test func skipWhenBecameExternalWithFile() {
        #expect(CoverRegen.writeDecision(liveIsExternal: true, liveThumbnailExists: true,
                                         snapshotPath: "/a", livePath: "/a") == .skipExternalRace)
    }
    @Test func externalRaceOnlyWhenFilePresent() {
        // external だがサムネ不在（＝fallback 継続中）は external race ではない
        #expect(CoverRegen.writeDecision(liveIsExternal: true, liveThumbnailExists: false,
                                         snapshotPath: "/a", livePath: "/a") == .write)
    }
    @Test func skipWhenPathChanged() {
        #expect(CoverRegen.writeDecision(liveIsExternal: false, liveThumbnailExists: false,
                                         snapshotPath: "/a", livePath: "/b") == .skipStaleRelink)
    }
    @Test func externalRaceBeatsStaleRelink() {
        #expect(CoverRegen.writeDecision(liveIsExternal: true, liveThumbnailExists: true,
                                         snapshotPath: "/a", livePath: "/b") == .skipExternalRace)
    }

    // shouldWritePageCount
    @Test func writePageCountWhenPathSame() {
        #expect(CoverRegen.shouldWritePageCount(snapshotPath: "/a", livePath: "/a") == true)
    }
    @Test func skipPageCountWhenPathChanged() {
        #expect(CoverRegen.shouldWritePageCount(snapshotPath: "/a", livePath: "/b") == false)
    }
}
