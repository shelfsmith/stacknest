// SPDX-License-Identifier: MIT
import Hummingbird
import StackNestL10n

/// G55: リクエストの Accept-Language を L10nLang.requestOverride に載せる。
/// ハンドラ内の L10n.text はこの言語で引かれ、HTTPError の message もこの言語になる。
/// ヘッダが無い（または空の）リクエストはサーバ自身の言語（`L10nLang.processDefault`）で答える。
/// タスクローカルなので、並行したリクエストの間で混ざらない。
struct LanguageMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request, context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let lang = L10nLang.from(acceptLanguage: request.headers[.acceptLanguage])
        return try await L10nLang.$requestOverride.withValue(lang) {
            try await next(request, context)
        }
    }
}
