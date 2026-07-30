// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("shouldPersistHashUpgrade — #8 の遅延移行を書き戻してよいか")
struct LockUpgradeGateTests {
    @Test("検証に使ったハッシュが今も現在値なら移行してよい")
    func persistsWhenUnchanged() {
        #expect(shouldPersistHashUpgrade(verifiedAgainst: "H1", current: "H1") == true)
    }

    @Test("★検証中に別のハッシュへ差し替えられていたら移行しない")
    func refusesWhenSwapped() {
        // 外部（CLI/MCP/共有サーバ）が新パスワード H2 を設定した後に、旧シートが H1 の検証を通した状況。
        // 無条件に書き戻すと H2 が旧パスワード由来のハッシュへ巻き戻る（ロックのダウングレード）。
        #expect(shouldPersistHashUpgrade(verifiedAgainst: "H1", current: "H2") == false)
    }

    @Test("施錠が解除されていたら移行しない")
    func refusesWhenLockRemoved() {
        #expect(shouldPersistHashUpgrade(verifiedAgainst: "H1", current: nil) == false)
    }

    @Test("空文字は現在値なしと同様に扱う")
    func refusesWhenCurrentEmpty() {
        #expect(shouldPersistHashUpgrade(verifiedAgainst: "H1", current: "") == false)
    }
}
