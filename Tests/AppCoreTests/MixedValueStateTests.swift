// SPDX-License-Identifier: MIT
import Testing
@testable import AppCore

@Suite("MixedValueState")
struct MixedValueStateTests {
    @Test func unanimousFromIdenticalValues() {
        let result = MixedValueState.from([3, 3, 3])
        #expect(result == .unanimous(3))
    }

    @Test func mixedFromDifferentValues() {
        let result = MixedValueState.from([1, 2, 3])
        #expect(result == .mixed)
    }

    @Test func unanimousFromSingleValue() {
        let result = MixedValueState.from([42])
        #expect(result == .unanimous(42))
    }

    @Test func unanimousFromEmptyArrayReturnsMixed() {
        let result: MixedValueState<Int> = .from([])
        #expect(result == .mixed)
    }

    // MARK: - shouldShowClearAction (Double? — VolumeEditorField)

    @Test func volumeFieldShowsClearWhenMixed() {
        // .mixed (複数選択で値が異なる) → クリアアクションを表示すべき
        let state: MixedValueState<Double?> = .mixed
        #expect(state.shouldShowClearAction == true)
    }

    @Test func volumeFieldShowsClearWhenUnanimousNonNil() {
        // .unanimous(non-nil) → クリアアクションを表示すべき
        let state: MixedValueState<Double?> = .unanimous(3.0)
        #expect(state.shouldShowClearAction == true)
    }

    @Test func volumeFieldHidesClearWhenUnanimousNil() {
        // .unanimous(nil) → 既にクリア済み → クリアアクション不要
        let state: MixedValueState<Double?> = .unanimous(nil)
        #expect(state.shouldShowClearAction == false)
    }
}
