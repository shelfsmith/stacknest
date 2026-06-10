// SPDX-License-Identifier: MIT
import Testing
import Hummingbird
import HummingbirdTesting
@testable import LibraryServer

@Suite("Static web assets")
struct StaticAssetsTests {
    private func makeApp() -> some ApplicationProtocol {
        LibraryServerCore(
            config: .init(port: 0, token: "tk"),
            dataSource: StaticLibraryDataSource(libraries: [])
        ).buildApplication()
    }

    /// ルート GET / が認証なしで Web クライアントの HTML を返す（ペアリング前に読み込めること）。
    @Test func indexHTMLIsServedWithoutAuth() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("<html"))
            }
        }
    }

    /// Web クライアントの app.js も認証なしで配信される（ES module の読み込み）。
    @Test func appJSIsServedWithoutAuth() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/app.js", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("StackNest"))
            }
        }
    }

    /// books ブラウズの ES module（books.js）も認証なしで配信される。
    @Test func booksJSIsServedWithoutAuth() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/books.js", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("renderBooks"))
            }
        }
    }

    /// 静的配信を足しても API の認証は維持される（回帰）。
    @Test func apiStillRequiresAuth() async throws {
        try await makeApp().test(.router) { client in
            try await client.execute(uri: "/api/v1/libraries", method: .get) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }
}
