import Testing
@testable import AppCore

@Suite("ViewerRegistryCore")
struct ViewerRegistryCoreTests {
    let a = ViewerIdentity.remote(serverID: "S", libraryUUID: "L", bookID: 1)
    let b = ViewerIdentity.remote(serverID: "S", libraryUUID: "L", bookID: 2)

    @Test func firstOpenProceeds() {
        var c = ViewerRegistryCore()
        #expect(c.begin(a) == .proceed)
        #expect(c.openingIdentities.contains(a))
    }

    @Test func duplicateWhileOpeningIsIgnored() {
        var c = ViewerRegistryCore()
        #expect(c.begin(a) == .proceed)
        #expect(c.begin(a) == .ignore)          // in-flight 連打を吸収
    }

    @Test func reopenOpenBookFocuses() {
        var c = ViewerRegistryCore()
        _ = c.begin(a); _ = c.finish(a, allowMultiple: true)
        #expect(c.begin(a) == .focusExisting)    // 既存窓は前面化
    }

    @Test func finishAllowMultipleKeepsOthers() {
        var c = ViewerRegistryCore()
        _ = c.begin(a); #expect(c.finish(a, allowMultiple: true).isEmpty)
        _ = c.begin(b); #expect(c.finish(b, allowMultiple: true).isEmpty)
        #expect(c.openIdentities == [a, b])
    }

    @Test func finishSingleClosesOthers() {
        var c = ViewerRegistryCore()
        _ = c.begin(a); _ = c.finish(a, allowMultiple: true)
        _ = c.begin(b)
        let toClose = c.finish(b, allowMultiple: false)   // OFF: 旧窓を閉じる
        #expect(toClose == [a])
        #expect(c.openIdentities == [b])
    }

    @Test func cancelClearsInFlight() {
        var c = ViewerRegistryCore()
        _ = c.begin(a); c.cancel(a)
        #expect(!c.openingIdentities.contains(a))
        #expect(c.begin(a) == .proceed)          // 失敗後は再度開ける
    }

    @Test func removeClearsOpen() {
        var c = ViewerRegistryCore()
        _ = c.begin(a); _ = c.finish(a, allowMultiple: true)
        c.remove(a); c.remove(a)                 // 冪等
        #expect(c.openIdentities.isEmpty)
    }

    // MARK: - G16 C1: reidentify（巻スワップで identity を張り替える）

    @Test func reidentifySwapsWhenFromIsOpen() {
        var c = ViewerRegistryCore()
        _ = c.begin(a); _ = c.finish(a, allowMultiple: true)
        c.reidentify(from: a, to: b)
        #expect(c.openIdentities == [b])
    }

    @Test func reidentifyIsNoOpWhenFromIsAbsent() {
        var c = ViewerRegistryCore()
        _ = c.begin(a); _ = c.finish(a, allowMultiple: true)
        c.reidentify(from: b, to: a)              // b は open に無い → 何もしない
        #expect(c.openIdentities == [a])
    }

    @Test func reidentifyDoesNotTouchOpening() {
        var c = ViewerRegistryCore()
        _ = c.begin(a)                            // opening のみ（finish していない）
        c.reidentify(from: a, to: b)
        #expect(c.openingIdentities.contains(a))  // opening は不変
        #expect(c.openIdentities.isEmpty)         // open は最初から空 → 何も変わらない
    }

    @Test func reidentifyToAlreadyOpenIsIdempotentish() {
        var c = ViewerRegistryCore()
        _ = c.begin(a); _ = c.finish(a, allowMultiple: true)
        _ = c.begin(b); _ = c.finish(b, allowMultiple: true)
        c.reidentify(from: a, to: b)              // to (b) は既に open
        #expect(c.openIdentities == [b])          // a は消え、b は 1 つのまま
    }
}
