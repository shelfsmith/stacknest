// SPDX-License-Identifier: MIT
import Foundation

/// G16 Codex Medium 修正: PATCH `/books/:id` の「本を読む → pre-image を作る → updateBook」臨界区間を
/// `(libraryUUID, bookID)` 単位で直列化する。
///
/// 背景: `resolveBook` が本を読み、その値から `previous`（undo 用 pre-image）を組み立て、その後
/// `updateBook` が走る。この一連の間に per-book のロックが無いため、同じ本への 2 件の PATCH が
/// ほぼ同時に届くと、両方が同じ「まだ更新されていない」行を読んで pre-image を作ってしまう。
/// 先に着いた方の更新を後に着いた方の pre-image が知らないまま undo すると、後者の undo が
/// 前者の編集結果を巻き戻してしまう（lost update）。
///
/// 対策: FIFO ハンドオフ方式のキー付き async ロック。`acquire` は空いていれば即座に返り、
/// 使用中なら FIFO で待つ。`release` は次の待機者がいればその継続を直接再開し（busy フラグは
/// 「保持したまま」次の所有者へ引き継ぐ）、いなければ busy を解放する。これにより
/// 「release の直後に別タスクの acquire が busy=false をすり抜けて先取りする」競合が起きない。
/// 同じ key 以外は完全並行のまま（別の本の PATCH は待たされない）。
actor PerBookSerializer {
    private struct Key: Hashable {
        let libraryUUID: String
        let bookID: Int
    }

    private var busy: Set<Key> = []
    private var waiters: [Key: [CheckedContinuation<Void, Never>]] = [:]

    /// key の所有権を獲得するまで一時停止する。
    func acquire(uuid: String, bookID: Int) async {
        let key = Key(libraryUUID: uuid, bookID: bookID)
        guard busy.contains(key) else {
            busy.insert(key)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[key, default: []].append(continuation)
        }
        // 再開された時点で busy は release 側が保持したままにしている（下記参照）ため、
        // ここで改めて insert する必要はない＝所有権はすでにこのタスクにある。
    }

    /// key の所有権を手放す。待機者がいれば FIFO で次の 1 件へ直接引き継ぐ。
    func release(uuid: String, bookID: Int) {
        let key = Key(libraryUUID: uuid, bookID: bookID)
        guard var queue = waiters[key], !queue.isEmpty else {
            busy.remove(key)
            return
        }
        let next = queue.removeFirst()
        waiters[key] = queue.isEmpty ? nil : queue
        // busy は true のまま（この key の所有権を次の継続へそのまま引き渡す）。
        next.resume()
    }
}
