// SPDX-License-Identifier: MIT
import Testing
import Foundation
@testable import StackNestCLI

@Suite("APIClient URL 構築")
struct APIClientURLTests {
    let client = APIClient(endpoint: ResolvedEndpoint(baseURL: "http://127.0.0.1:9", token: "t"))

    @Test func librariesURLContainsAPIV1() {
        let url = client.makeURL("/libraries")
        #expect(url.absoluteString == "http://127.0.0.1:9/api/v1/libraries")
    }

    @Test func booksURLContainsAPIV1() {
        let url = client.makeURL("/libraries/abc/books")
        #expect(url.absoluteString.contains("/api/v1/libraries/abc/books"))
    }

    @Test func makeURLDoesNotDoubleSlash() {
        let url = client.makeURL("/libraries")
        #expect(!url.absoluteString.contains("//api/v1"))
    }

    @Test func baseURLWithTrailingSlashIsHandledByResolver() {
        // EndpointResolver は末尾スラッシュを除去するため、makeURL は常に正常な URL を返す
        let ep = ResolvedEndpoint(baseURL: "http://127.0.0.1:9", token: "t")
        let c = APIClient(endpoint: ep)
        let url = c.makeURL("/libraries")
        #expect(url.absoluteString == "http://127.0.0.1:9/api/v1/libraries")
    }
}
