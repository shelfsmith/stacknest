// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import AppCore

@Suite("AppError errorDescription — Japanese")
struct AppErrorMessageTests {
    @Test
    func launchFailedFormatsJapanese() {
        let err = AppError.launchFailed(path: "/tmp/x.zip", reason: "ファイルが見つかりません。")
        #expect(err.errorDescription == "\"/tmp/x.zip\"を開けませんでした: ファイルが見つかりません。")
    }

    @Test
    func titleRequiredIsJapanese() {
        #expect(AppError.titleRequired.errorDescription == "タイトルは必須項目です")
    }

    @Test
    func unexpectedIsJapanese() {
        struct E: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let err = AppError.unexpected(E())
        #expect(err.errorDescription == "予期しないエラー: boom")
    }
}
