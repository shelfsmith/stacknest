// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("GridNavigator.nextIndex / firstIndex")
struct GridNavigatorTests {
    // MARK: - 4×4 grid (total=16, columns=4) の基本移動

    @Test
    func upDownLeftRightFromCenter() {
        // index 5 = 2 行目左から 2 列目
        #expect(GridNavigator.nextIndex(current: 5, direction: .up,    total: 16, columns: 4) == 1)
        #expect(GridNavigator.nextIndex(current: 5, direction: .down,  total: 16, columns: 4) == 9)
        #expect(GridNavigator.nextIndex(current: 5, direction: .left,  total: 16, columns: 4) == 4)
        #expect(GridNavigator.nextIndex(current: 5, direction: .right, total: 16, columns: 4) == 6)
    }

    @Test
    func topLeftCornerStopsAtUpAndLeft() {
        // index 0 = 一番上の左端
        #expect(GridNavigator.nextIndex(current: 0, direction: .up,   total: 16, columns: 4) == nil)
        #expect(GridNavigator.nextIndex(current: 0, direction: .left, total: 16, columns: 4) == nil)
        #expect(GridNavigator.nextIndex(current: 0, direction: .down,  total: 16, columns: 4) == 4)
        #expect(GridNavigator.nextIndex(current: 0, direction: .right, total: 16, columns: 4) == 1)
    }

    @Test
    func bottomRightCornerStopsAtDownAndRight() {
        // index 15 = 一番下の右端
        #expect(GridNavigator.nextIndex(current: 15, direction: .down,  total: 16, columns: 4) == nil)
        #expect(GridNavigator.nextIndex(current: 15, direction: .right, total: 16, columns: 4) == nil)
        #expect(GridNavigator.nextIndex(current: 15, direction: .up,    total: 16, columns: 4) == 11)
        #expect(GridNavigator.nextIndex(current: 15, direction: .left,  total: 16, columns: 4) == 14)
    }

    @Test
    func rowBoundariesDoNotWrap() {
        // 1 行目の右端 (index 3) から → は wrap せず nil
        #expect(GridNavigator.nextIndex(current: 3, direction: .right, total: 16, columns: 4) == nil)
        // 2 行目の左端 (index 4) から ← は wrap せず nil
        #expect(GridNavigator.nextIndex(current: 4, direction: .left, total: 16, columns: 4) == nil)
    }

    // MARK: - 半端最終行の clamp

    @Test
    func downFromShortFinalRowClamps() {
        // total=11, columns=4 → 最終行は index 8, 9, 10 (3 cells)
        // index 5 (2 行目右から 2 番目) から ↓ → targetIndex=9 (= 最終行同列) → そのまま 9 を返す
        #expect(GridNavigator.nextIndex(current: 5, direction: .down, total: 11, columns: 4) == 9)
        // index 7 (2 行目最右) から ↓ → targetIndex=11 だが total=11、最終行は 8〜10、最右は 10 → clamp して 10
        #expect(GridNavigator.nextIndex(current: 7, direction: .down, total: 11, columns: 4) == 10)
    }

    // MARK: - 1 列 grid

    @Test
    func singleColumnGridUpDownOnly() {
        // columns=1, total=5: 0,1,2,3,4 が縦 1 列
        #expect(GridNavigator.nextIndex(current: 2, direction: .up,    total: 5, columns: 1) == 1)
        #expect(GridNavigator.nextIndex(current: 2, direction: .down,  total: 5, columns: 1) == 3)
        #expect(GridNavigator.nextIndex(current: 2, direction: .left,  total: 5, columns: 1) == nil)
        #expect(GridNavigator.nextIndex(current: 2, direction: .right, total: 5, columns: 1) == nil)
        #expect(GridNavigator.nextIndex(current: 0, direction: .up,    total: 5, columns: 1) == nil)
        #expect(GridNavigator.nextIndex(current: 4, direction: .down,  total: 5, columns: 1) == nil)
    }

    // MARK: - 空 list

    @Test
    func emptyTotalReturnsNilForAllDirections() {
        for dir in [GridNavigator.Direction.up, .down, .left, .right] {
            #expect(GridNavigator.nextIndex(current: 0, direction: dir, total: 0, columns: 4) == nil)
        }
    }

    // MARK: - firstIndex

    @Test
    func firstIndexReturnsZeroForNonEmpty() {
        #expect(GridNavigator.firstIndex(total: 5) == 0)
        #expect(GridNavigator.firstIndex(total: 1) == 0)
    }

    @Test
    func firstIndexReturnsNilForEmpty() {
        #expect(GridNavigator.firstIndex(total: 0) == nil)
    }

    // MARK: - lastIndex

    @Test
    func lastIndexReturnsTotalMinusOneForNonEmpty() {
        #expect(GridNavigator.lastIndex(total: 5) == 4)
        #expect(GridNavigator.lastIndex(total: 1) == 0)
    }

    @Test
    func lastIndexReturnsNilForEmpty() {
        #expect(GridNavigator.lastIndex(total: 0) == nil)
    }
}
