// SPDX-License-Identifier: MIT
import Foundation
import AppCore
import LibraryStore
import LibraryServerAPI
import RemoteClient

/// G60: 対応した外部ビューアへ、本を読むための口（参照ファイル `.stacknestbook`）を渡す（spec §5）。
///
/// ローカルの書庫の本は手元でトークンを出して 127.0.0.1 の口を指し、リモートの本はサーバに出してもらう
/// （中継のときは手元の口を指す）。参照ファイルを書いて、画像の本の外部ビューアで開く。
/// 失敗したら理由（`Failure`）を返し、呼び出し側が従来の開き方に戻して理由を出す。
///
/// G60 v3: 渡す先は `StackNestViewerSupport` を宣言したアプリだけ（`ReferenceViewer`・呼び出し側が引く）。
/// **起動するのは、その確認で得た `viewer.appURL`**（設定を引き直さない。確認と起動の間に設定が変わっても、
/// 確かめたアプリに渡す）。渡してから `ViewerSettings.viewerUseCheckDelay`（既定 15 秒）後に一度だけトークンが
/// 使われたかを確かめ、使われていなければ `onNotUsed` で呼び出し側に知らせる（spec §5.7）。**トークンは取り消さない。**
///
/// 依存はすべてプロパティにしてある。テストは UserDefaults.standard・実ポート・`LastReadTracker.shared` に
/// 触れずに差し替える（テストホストは本物のアプリと同じ defaults の領域を使うため）。
@MainActor
struct ExternalViewerHandoff {
    var tokens: ViewerTokenStore
    var references: BookReferenceStore
    var localPort: () -> Int
    var isLocalEndpointRunning: () -> Bool
    var recordLastRead: (LastReadBook) -> Void
    var now: () -> Date
    /// G60 v3（spec §5.8・試用）: リモートの本の中継の記録（メモリだけ）。127.0.0.1 の口と同じインスタンス。
    var relays: ViewerRelayRegistry
    /// G60 v3: リモートの本を中継するか。本番は `ExternalViewerSyncRouting.relaysRemoteBooks`（判断は 1 か所）。
    var relaysRemoteBooks: Bool
    /// G60 v3: 参照ファイルを渡してから、使われたかを確かめるまで待つ処理。本番は `Task.sleep`。
    /// 投げたら（取り消し）確かめない。
    var sleep: @Sendable (Duration) async throws -> Void
    /// G60 v3: 確認できた対応ビューアの記録（設定の状態の行が読む）。
    var confirmedViewers: ConfirmedViewerStore
    /// G60 §5.9（2026-10-08 作者の決定）: 中継の本を渡せたら、その本の先読みを始める（127.0.0.1 の口の中継が持つ
    /// 先読み係。範囲は設定に従う。前に渡した本の先読みは止まる）。引数は中継の id と開くページ。
    var startRelayPrefetch: @MainActor (_ relayID: String, _ focus: Int) async -> Void

    static var live: ExternalViewerHandoff {
        ExternalViewerHandoff(
            tokens: .shared,
            references: BookReferenceStore(),
            localPort: { ServerPreferences.localControlPort() },
            isLocalEndpointRunning: { LocalControlController.shared.isRunning },
            recordLastRead: { LastReadTracker.shared.record($0) },
            now: { Date() },
            relays: .shared,
            relaysRemoteBooks: ExternalViewerSyncRouting.relaysRemoteBooks,
            sleep: { try await Task.sleep(for: $0) },
            confirmedViewers: .shared,
            startRelayPrefetch: { relayID, focus in
                await LocalControlController.shared.viewerRelay.startPrefetch(relayID: relayID, focus: focus)
            })
    }

    enum Failure: Error, Equatable {
        case localEndpointNotRunning
        case pageCountUnavailable
        case tokenUnavailable
        /// 旧サーバ（`POST …/viewer-token` のルートが無い＝404、または未実装の 501）。G60 より前と同じ挙動なので、
        /// 呼び出し側は理由を出さずに内蔵ビューアで開く。
        case unsupportedByServer
        case referenceNotWritten
        case launchFailed(String)
        /// このウィンドウが解錠していない（または解錠後に変えられた）ロックの書庫。何も開かない。
        case libraryLocked

        /// 画面に出す理由（「…ため、…で開きました（理由）」の括弧の中）。
        var reason: String {
            switch self {
            case .localEndpointNotRunning:
                return String(localized: "ローカルコントロールの受け口（127.0.0.1）が動いていません")
            case .pageCountUnavailable:
                return String(localized: "本のページ数を読めませんでした")
            case .tokenUnavailable, .unsupportedByServer:
                return String(localized: "トークンを発行できませんでした")
            case .referenceNotWritten:
                return String(localized: "参照ファイルを書き出せませんでした")
            case .launchFailed(let message):
                return message
            case .libraryLocked:
                return String(localized: "ライブラリのパスワードが変更されました。解錠し直してください。")
            }
        }
    }

    /// G60 v3: 参照ファイルを渡した後の確認の結果（spec §5.7）。
    enum UseOutcome: Equatable, Sendable {
        /// ビューアがトークンで本を読んだ（初めて通った日時と名乗り）。
        case used(firstUsedAt: Date, viewer: String?)
        /// 待った後もまだ使われていない。
        case notUsed
        /// 確かめられなかった（照会の失敗・記録が無い・待ちの取り消し）。何も出さない。
        case unknown
    }

    /// 渡す前に用意した 1 冊（鍵を出し、参照ファイルの中身を組んだところまで）。書き出しと起動は `deliver` がまとめて行う。
    struct PreparedHandoff {
        let reference: StackNestBookReference
        let origin: BookReferenceStore.Origin
        let libraryUUID: String
        let bookID: Int
        /// 使われたかの確かめ方（nil なら確かめない・v2 のサーバ）。
        let readUse: (@Sendable () async -> UseOutcome)?
        let onNotUsed: @MainActor @Sendable (String) -> Void
        let onUsed: @MainActor @Sendable () -> Void
        var cancelsOnClose = false
        var onCheckStarted: @MainActor (Task<Void, Never>, _ cancelsOnClose: Bool) -> Void = { _, _ in }
        /// 渡す直前の確かめ直し（渡せないなら理由）。用意から渡すまでに、ほかの本の用意を待つ間が空くので、その間の施錠・
        /// 127.0.0.1 の口の停止をここで見る（`prepareLocal` が用意の最後に見るのと同じ条件）。
        var recheck: @MainActor () -> Failure? = { nil }
    }

    /// ローカルの書庫の本。127.0.0.1 の口で使えるトークンを手元で出す（HTTP を通さない・spec §5.2）。
    /// グラントに結び付けない（`issuedByGrantID` は nil）。本人の Mac の中だけの口なので。
    func openLocal(book: BookRow, libraryUUID: String, viewer: ReferenceViewer,
                   lockCredential: @escaping () -> String?, verifiedLockHash: @escaping () -> String?,
                   startPage: Int,
                   direction: PageDirection, settings: ViewerSettings,
                   userExtensions: UserExtensionMap = UserExtensionStore.shared.snapshot,
                   onNotUsed: @escaping @MainActor @Sendable (_ viewerName: String) -> Void = { _ in },
                   onUsed: @escaping @MainActor @Sendable () -> Void = {}) async -> Failure? {
        switch await prepareLocal(book: book, libraryUUID: libraryUUID, viewer: viewer, lockCredential: lockCredential,
                                  verifiedLockHash: verifiedLockHash, startPage: startPage, direction: direction,
                                  userExtensions: userExtensions, onNotUsed: onNotUsed, onUsed: onUsed) {
        case .failure(let failure): return failure
        case .success(let prepared): return deliver([prepared], viewer: viewer, settings: settings)[0]
        }
    }

    /// ローカルの書庫の本を渡す用意（`openLocal` の前半: ページ数・ロックの照合・鍵・参照ファイルの中身）。
    /// 複数の本を選んだときは、全部を用意してから `deliver` で 1 回の `open` にまとめて渡す。
    func prepareLocal(book: BookRow, libraryUUID: String, viewer: ReferenceViewer,
                      lockCredential: @escaping () -> String?, verifiedLockHash: @escaping () -> String?,
                      startPage: Int, direction: PageDirection,
                      userExtensions: UserExtensionMap = UserExtensionStore.shared.snapshot,
                      onNotUsed: @escaping @MainActor @Sendable (_ viewerName: String) -> Void = { _ in },
                      onUsed: @escaping @MainActor @Sendable () -> Void = {}) async -> Result<PreparedHandoff, Failure> {
        guard isLocalEndpointRunning() else { return .failure(.localEndpointNotRunning) }
        guard let path = book.path, !path.isEmpty else { return .failure(.pageCountUnavailable) }
        let pageCount: Int
        do {
            // 渡す前の「読めるか」の確認（AppState.servesPagesByReference）と同じ一覧で読む（gzip の tar を読むかが一覧で決まる）。
            pageCount = try await BookContentFactory.make(for: book, userExtensions: userExtensions).pageCount
        } catch {
            return .failure(.pageCountUnavailable)
        }
        guard pageCount > 0 else { return .failure(.pageCountUnavailable) }
        // G25d: ロックの値は発行の直前に読み、「このウィンドウが検証したハッシュ」と一致するときだけ結び付ける
        // （ページ数の待ちの間に外部から施錠・変更されうる）。有って違うなら発行しない。
        let lock = lockCredential()
        if let lock, lock != verifiedLockHash() { return .failure(.libraryLocked) }
        // Codex P2（`openRemote` の鍵の往復と同じ）: ページ数の待ちのあいだに口が止まっていたら、鍵を出さない
        // （読めない参照ファイルを渡さず、呼び出し側がファイルで開く）。
        guard isLocalEndpointRunning() else { return .failure(.localEndpointNotRunning) }
        // 本の印に結び付ける（本の番号が使い回されても、別の本には効かない・Codex P1）。
        let issued = tokens.issue(libraryUUID: libraryUUID, bookID: book.id,
                                  bookStamp: ViewerTokenRecord.bookStamp(dateAdded: book.dateAdded), issuer: .localEndpoint,
                                  lockCredential: lock, now: now())
        // ポートは参照ファイルを組む直前に読む（口がポート競合で取り直していても、その時点の値を使う。
        // `isLocalEndpointRunning` はバインド前から true なので、取り直しの最中に開くと古いポートを指しうる。
        // その場合は開き直せば直る＝許容）。
        guard let base = URL(string: "http://127.0.0.1:\(localPort())/") else { return .failure(.referenceNotWritten) }
        let reference: StackNestBookReference
        do {
            // G63 段 4: 部品の型は、読む側が断る値（ページ数の上限・鍵の文字など）では作れない。作れなければ渡さない
            // （書き出しの失敗と同じ扱い。呼び出し側は従来の開き方に戻す）。
            reference = try StackNestBookReference(
                version: viewer.formatVersion,
                title: book.title,
                bookURL: BookReferences.bookURL(serverBase: base, libraryUUID: libraryUUID, bookID: book.id),
                token: issued.token,
                expiresAt: issued.record.expiresAt,
                pageCount: pageCount,
                direction: BookReferences.direction(direction),
                startPage: StackNestBookReference.clampedStartPage(startPage, pageCount: pageCount))
        } catch {
            return .failure(.referenceNotWritten)
        }
        // 確認は、127.0.0.1 の口と同じトークンの保存先を直接読む（HTTP を通さない・spec §5.7）。
        let tokens = self.tokens
        let tokenID = issued.record.id
        let isLocalEndpointRunning = self.isLocalEndpointRunning
        return .success(PreparedHandoff(
            reference: reference, origin: .local, libraryUUID: libraryUUID, bookID: book.id,
            readUse: { Self.outcome(of: tokens.record(id: tokenID)) },
            onNotUsed: onNotUsed, onUsed: onUsed,
            recheck: {
                // 鍵は発行の時点のロックの値に結び付いている。その後に施錠・変更されたら、口はこの鍵を断る。
                if let current = lockCredential(), current != lock || current != verifiedLockHash() {
                    return .libraryLocked
                }
                return isLocalEndpointRunning() ? nil : .localEndpointNotRunning
            }))
    }

    /// リモートの本。サーバに `POST …/viewer-token` で出してもらう（`issue`）。
    /// G60 v3（spec §5.8・試用）: `relaysRemoteBooks` なら、ビューアには手元の 127.0.0.1 の口の中継
    /// （`…/api/v1/relay/<relayID>`）と中継の鍵を渡し、リモートの鍵は中継の記録（メモリ）にだけ置く。
    /// 確認はローカルの本と同じく中継の鍵の初回使用を手元の保存先で読む（照会 API は使わない）。
    /// そうでなければ（直接つなぐ形）基点はこのクライアントがサーバへ繋いでいる URL で、鍵はリモートの鍵、
    /// 確認は `fetchStatus`（`GET /viewer-tokens/{tokenID}`）。v2 のサーバ（`tokenID` を返さない）なら確認しない。
    /// `startPage` は呼び出し側が解決した続きのページ（内蔵と同じ `resolveResumePage`）。ここで範囲に収める。
    func openRemote(book: BookListItemDTO, manifest: ManifestDTO, viewer: ReferenceViewer, serverID: UUID,
                    serverBase: URL, libraryUUID: String, startPage: Int, settings: ViewerSettings,
                    issue: () async throws -> ViewerTokenReply,
                    fetchStatus: @escaping @Sendable (_ tokenID: String) async throws -> ViewerTokenStatusReply,
                    onNotUsed: @escaping @MainActor @Sendable (_ viewerName: String) -> Void = { _ in },
                    onUsed: @escaping @MainActor @Sendable () -> Void = {},
                    onCheckStarted: @escaping @MainActor (Task<Void, Never>, _ cancelsOnClose: Bool) -> Void = { _, _ in }) async -> Failure? {
        // 中継には 127.0.0.1 の口が要る。動いていなければリモートの鍵も出してもらわない。
        if relaysRemoteBooks, !isLocalEndpointRunning() { return .localEndpointNotRunning }
        let reply: ViewerTokenReply
        do {
            reply = try await issue()
        } catch RemoteClientError.notFound {
            return .unsupportedByServer
        } catch RemoteClientError.server(501) {
            return .unsupportedByServer
        } catch RemoteClientError.libraryLocked {
            // 施錠ゲートの 403（パスワード変更など）。呼び出し側は解錠へ戻し、何も開かない。
            return .libraryLocked
        } catch {
            return .tokenUnavailable
        }
        // G60 §5.9（最終レビュー m4）: 鍵を出してもらう往復のあいだに口が止まっていたら（同期とローカルコントロールを
        // OFF にした）、中継の記録も参照ファイルも作らず、先読みも始めない。出してもらったリモートの鍵は使われずに切れる。
        if relaysRemoteBooks, !isLocalEndpointRunning() { return .localEndpointNotRunning }
        let bookURL: URL
        let token: String
        let expiresAt: Date
        var readUse: (@Sendable () async -> UseOutcome)?
        // G60 §5.9: 渡せたら先読みする中継（中継のときだけ）。
        var prefetchRelayID: String?
        if relaysRemoteBooks {
            // 中継の記録の期限・中継の鍵の期限・参照ファイルの期限を同じ時刻から決める。
            let issuedAt = now()
            // 先に切れる方に合わせる（リモートの鍵が切れたら、中継しても 401）。中継の記録もこの時刻で消える。
            let relayExpiry = min(issuedAt.addingTimeInterval(ViewerTokenStore.lifetime), reply.expiresAt)
            // 中継の記録を先に登録してから鍵を出す（起動時の孤児の掃除が、出したばかりの鍵を消さないように）。
            // G60 §5.9: 渡す時点の manifest のページ数と etag も持たせる（キャッシュのキーの版と先読みの範囲）。
            let relayID = relays.register(ViewerRelayTarget(
                serverID: serverID, serverBase: serverBase, libraryUUID: libraryUUID, bookID: book.id,
                remoteToken: reply.token, pageCount: manifest.pageCount, manifestETag: manifest.etag),
                expiresAt: relayExpiry, now: issuedAt)
            prefetchRelayID = relayID
            // 中継の鍵の記録には本物の書庫・本を持たせない（見張り用の値。本物は中継の記録だけ・M-3）。
            let local = tokens.issue(libraryUUID: ViewerTokenRecord.relaySentinelLibraryUUID,
                                     bookID: ViewerTokenRecord.relaySentinelBookID, issuer: .localEndpoint,
                                     lockCredential: nil, relayID: relayID, now: issuedAt)
            // ポートは参照ファイルを組む直前に読む（ローカルの本と同じ）。
            guard let base = URL(string: "http://127.0.0.1:\(localPort())/") else { return .referenceNotWritten }
            bookURL = BookReferences.relayURL(localBase: base, relayID: relayID)
            token = local.token
            expiresAt = min(local.record.expiresAt, reply.expiresAt)
            // 確認はローカルの本と同じく、手元の保存先の中継の鍵の初回使用を読む（照会 API は使わない）。
            // 中継の鍵の初回使用は「有効な中継の鍵で口に届いた」こと（リモートが 502 でも記録される・意図した動き）。
            let relayTokens = self.tokens
            let relayTokenID = local.record.id
            readUse = { Self.outcome(of: relayTokens.record(id: relayTokenID)) }
        } else {
            bookURL = BookReferences.bookURL(serverBase: serverBase, libraryUUID: libraryUUID, bookID: book.id)
            token = reply.token
            expiresAt = reply.expiresAt
            // v2 のサーバは tokenID を返さない。そのときは確認を走らせない（参照ファイルでは渡す＝v2 と同じ振る舞い）。
            if let tokenID = reply.tokenID {
                readUse = {
                    // 照会に失敗したら確かめられない（知らせない）。
                    do {
                        let status = try await fetchStatus(tokenID)
                        guard let usedAt = status.firstUsedAt else { return .notUsed }
                        return .used(firstUsedAt: usedAt, viewer: status.viewer)
                    } catch {
                        return .unknown
                    }
                }
            }
        }
        let reference: StackNestBookReference
        do {
            // G63 段 4: 作れなければ渡さない（`openLocal` と同じ）。中継の記録と中継の鍵は、書き出しの失敗のときと
            // 同じく使われずに期限で消える。先読みも始めない（下の `failure == nil` の条件）。
            reference = try StackNestBookReference(
                version: viewer.formatVersion,
                title: book.title,
                bookURL: bookURL,
                token: token,
                expiresAt: expiresAt,
                pageCount: manifest.pageCount,
                direction: StackNestReadingDirection(rawValue: manifest.direction),
                startPage: StackNestBookReference.clampedStartPage(startPage, pageCount: manifest.pageCount))
        } catch {
            return .referenceNotWritten
        }
        let failure = hand(reference, origin: .remote(serverID: serverID), libraryUUID: libraryUUID, bookID: book.id,
                           settings: settings, viewer: viewer, readUse: readUse, onNotUsed: onNotUsed, onUsed: onUsed,
                           cancelsOnClose: !relaysRemoteBooks, onCheckStarted: onCheckStarted)
        // G60 §5.9（2026-10-08 作者の決定）: 中継の本を渡せたら、裏で先読みしてリモートのキャッシュに入れる
        // （内蔵ビューアと分け合う）。範囲は「開いた本を全ページ先読みする」に従い、先読み係が決める（ON＝全ページ・
        // OFF＝近傍だけ）。中心は開くページ。前に渡した本の先読みは止まる。渡せなかったら先読みしない。
        if failure == nil, let prefetchRelayID {
            await startRelayPrefetch(prefetchRelayID, reference.startPage)
        }
        return failure
    }

    /// 組の印（16 バイトの乱数の base64url・22 文字。`StackNestHandoffGroup` の約束の 8〜64 文字に収まる）。
    static func makeHandoffID() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// G60 v3: 待ってから 1 度だけ確かめる。待ちが取り消されたら確かめない（`.unknown`）。
    static func checkUse(after delay: Duration,
                         sleep: @Sendable (Duration) async throws -> Void,
                         read: @Sendable () async -> UseOutcome) async -> UseOutcome {
        do { try await sleep(delay) } catch { return .unknown }
        return await read()
    }

    /// G60 v3: 保存先の記録から確認の結果を作る（ローカルの本・中継の鍵）。記録が無い（掃除された）なら確かめられない。
    nonisolated static func outcome(of record: ViewerTokenRecord?) -> UseOutcome {
        guard let record else { return .unknown }
        guard let usedAt = record.firstUsedAt else { return .notUsed }
        return .used(firstUsedAt: usedAt, viewer: record.viewer)
    }

    private func hand(_ reference: StackNestBookReference, origin: BookReferenceStore.Origin, libraryUUID: String,
                      bookID: Int, settings: ViewerSettings, viewer: ReferenceViewer,
                      readUse: (@Sendable () async -> UseOutcome)?,
                      onNotUsed: @escaping @MainActor @Sendable (String) -> Void,
                      onUsed: @escaping @MainActor @Sendable () -> Void,
                      cancelsOnClose: Bool = false,
                      onCheckStarted: @escaping @MainActor (Task<Void, Never>, _ cancelsOnClose: Bool) -> Void = { _, _ in }) -> Failure? {
        deliver([PreparedHandoff(reference: reference, origin: origin, libraryUUID: libraryUUID, bookID: bookID,
                                 readUse: readUse, onNotUsed: onNotUsed, onUsed: onUsed, cancelsOnClose: cancelsOnClose,
                                 onCheckStarted: onCheckStarted)],
                viewer: viewer, settings: settings)[0]
    }

    /// 用意した本（`prepareLocal` など）の参照ファイルを書き、**1 回の `open` にまとめて**同じビューアへ渡し、それぞれの
    /// 使われたかの確認を始める。返す配列は `items` と同じ順で、その本を渡せなかった理由（渡せたら nil）。
    ///
    /// まとめるのは、複数の本を選んで開いたとき、ビューアが Finder で複数を選んで開いたときと同じく 1 回の「開く」として
    /// 受け取れるようにするため（1 冊ずつ `open` すると、渡す間に書庫を読むぶん間が空き、ビューアからはどこまでが 1 回の
    /// 選択か分からない）。書けなかった本だけを外して残りを渡す。起動に失敗したら、書いた本はどれも `.launchFailed`。
    ///
    /// 2 冊以上を渡すときは、どの参照ファイルにも同じ組の印（`handoff`: 乱数の `id`・選んだ順の `index`・冊数 `count`）を
    /// 入れる。ビューアは届き方（1 回の「開く」で届くか・届く順）に頼らずに、組と並びが分かる。組を知らないビューアは
    /// 知らない項目として読み飛ばす（形式の版 1 のまま足せる項目）。書けなかった本があると組は `count` に満たないが、
    /// ビューアは揃うのを待ち続けない約束（形式の文書）。
    func deliver(_ items: [PreparedHandoff], viewer: ReferenceViewer, settings: ViewerSettings) -> [Failure?] {
        var failures = [Failure?](repeating: nil, count: items.count)
        var written: [(index: Int, url: URL)] = []
        // 渡す直前の確かめ直しに通った本だけで組を作る（通らなかった本の分だけ組が欠け、ビューアが揃うのを待たないように）。
        var passing: [Int] = []
        for (index, item) in items.enumerated() {
            if let failure = item.recheck() {
                failures[index] = failure
            } else {
                passing.append(index)
            }
        }
        // 組の冊数は約束の上限（`StackNestHandoffGroup.maxCount`）までで、超えると組を作れず印を付けない（ばらばらの本として渡す）。
        let groupID = passing.count >= 2 ? Self.makeHandoffID() : nil
        for (position, index) in passing.enumerated() {
            let item = items[index]
            let group = groupID.flatMap { try? StackNestHandoffGroup(id: $0, index: position, count: passing.count) }
            do {
                written.append((index, try references.write(item.reference.with(handoff: group), origin: item.origin,
                                                            libraryUUID: item.libraryUUID, bookID: item.bookID)))
            } catch {
                failures[index] = .referenceNotWritten
            }
        }
        guard !written.isEmpty else { return failures }
        // 確かめたビューア（`viewer.appURL`）をそのまま起動する。設定は引き直さない（I-1）。
        if let error = HelperLauncher.openReferences(written.map(\.url), viewer: viewer) {
            for entry in written { failures[entry.index] = .launchFailed(error.localizedDescription) }
            return failures
        }
        for entry in written {
            let item = items[entry.index]
            // 確かめる手段が無い（v2 のサーバ）なら確認しない。
            if let readUse = item.readUse {
                item.onCheckStarted(startUseCheck(delay: settings.viewerUseCheckDelay, viewer: viewer, read: readUse,
                                                  onNotUsed: item.onNotUsed, onUsed: item.onUsed), item.cancelsOnClose)
            }
        }
        return failures
    }

    /// G60 v3: 渡してから一定時間後に一度だけ確かめる（spec §5.7）。使われていなければ呼び出し側に知らせ、
    /// 従来の開き方のボタンを出してもらう。トークンは取り消さない（ビューアが遅れて読み始めても動くように）。
    /// 使われていたら、渡した先のアプリを「確認できた対応ビューア」として記録し（鍵はアプリの bundle id・版は名乗り）、
    /// `onUsed`（前の渡しで出した「読み込んでいません」を呼び出し側が消す）。
    /// 確認は 1 回だけで、お知らせを消すために照会を繰り返さない。返す Task は呼び出し側が閉じるときに取り消せる（取り消すのは HTTP で照会する直接つなぐ形だけ。手元の保存先を読む確認は窓と無関係に走らせる）。
    private func startUseCheck(delay: Duration, viewer: ReferenceViewer,
                               read: @escaping @Sendable () async -> UseOutcome,
                               onNotUsed: @escaping @MainActor @Sendable (String) -> Void,
                               onUsed: @escaping @MainActor @Sendable () -> Void) -> Task<Void, Never> {
        let sleep = self.sleep
        let confirmedViewers = self.confirmedViewers
        let name = viewer.declaration.displayName
        let appBundleIdentifier = viewer.declaration.bundleIdentifier
        return Task { @MainActor in
            switch await Self.checkUse(after: delay, sleep: sleep, read: read) {
            case .notUsed:
                onNotUsed(name)
            case .used(let firstUsedAt, let identification):
                confirmedViewers.record(appBundleIdentifier: appBundleIdentifier, viewer: identification, at: firstUsedAt)
                onUsed()
            case .unknown:
                break
            }
        }
    }
}

/// G60 v3: 設定の「外部ビューア」の節に出す、対応の状態の 1 行（spec §5.7）。行を出さないときは nil。
enum ExternalViewerSupportStatusText {
    static func line(_ status: ExternalViewerSupportStatus) -> String? {
        switch status {
        case .none:
            return nil
        case .unsupported(let name):
            return String(localized: "\(name)：未対応（今までどおり開きます）")
        case .declared(let name):
            return String(localized: "\(name)：対応を宣言（未確認）")
        case .confirmed(let name, let at, let version):
            let date = at.formatted(date: .abbreviated, time: .shortened)
            if let version {
                return String(localized: "\(name)：対応を確認（\(date)・\(version)）")
            }
            return String(localized: "\(name)：対応を確認（\(date)）")
        }
    }
}
