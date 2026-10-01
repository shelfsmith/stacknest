#!/usr/bin/env bash
# 公開の場（この repo・上流 Washi への push と Issue/PR）に個人識別子を出さないための検査。
# 2026-10-01: 実名がコードのコメントに入ったまま main に push されていた事故を受けて機械化した。
#
# 検査する語の一覧はリポジトリの外に置く（中身そのものが識別子なので、ここには書かない）:
#   ${STACKNEST_PRIVATE_IDENTIFIERS_FILE:-$HOME/.config/stacknest/private-identifiers}
#   1 行 1 つの拡張正規表現・大文字小文字を区別しない・# で始まる行と空行は無視。
# 一覧が無い・空のときは失敗する（見落とすより止まる方を選ぶ）。
#
# 使い方:
#   check-private-identifiers.sh pre-push          pre-push フックの標準入力（ref の組）を読み、
#                                                  push する先端のファイル全体・新しいコミットで
#                                                  足された行とファイル名・メッセージ・作成者を検査する
#   check-private-identifiers.sh tree <rev>        <rev> のファイル全体を検査する
#   check-private-identifiers.sh text [file...]    ファイル（無ければ標準入力）の文面を検査する
# 見つかったら該当箇所を出して終了コード 1。見つからなければ 0。
set -euo pipefail

LIST="${STACKNEST_PRIVATE_IDENTIFIERS_FILE:-$HOME/.config/stacknest/private-identifiers}"
ZERO="0000000000000000000000000000000000000000"

fail() { echo "private-identifiers: $*" >&2; exit 1; }

[ -r "$LIST" ] || fail "identifier list not found: $LIST (refusing; create it before pushing or posting)"
PATTERNS="$(mktemp -t private-identifiers)"
trap 'rm -f "$PATTERNS"' EXIT
grep -v -E '^[[:space:]]*(#|$)' "$LIST" > "$PATTERNS" || true
[ -s "$PATTERNS" ] || fail "identifier list is empty: $LIST (refusing)"

found=0

# <rev> のファイル全体（バイナリは除く）
check_tree() {
    local rev="$1" rc=0
    git grep -I -n -i -E -f "$PATTERNS" "$rev" -- . >&2 || rc=$?
    case "$rc" in
    0) echo "private-identifiers: personal identifier found in the files of $rev" >&2; found=1 ;;
    1) ;;                                              # 一致なし
    *) fail "git grep failed on $rev (exit $rc)" ;;    # 一致なしと取り違えない
    esac
}

# 範囲内の各コミットで足された行（途中のコミットで入れて後で消した識別子も公開されるため。
# 消した行は見ない — 見ると、識別子を消すコミットそのものが止まる）。マージのコミットは第 1 親との
# 差分として見る（衝突の解消の中で入った行も拾う）
check_patches() {
    local patch hits
    patch="$(git log -p --diff-merges=first-parent --no-color --no-ext-diff --format='commit %h' "$@")" \
        || fail "git log -p failed: $*"
    hits="$(printf '%s\n' "$patch" | grep -E '^(commit |\+)' | grep -v -E '^\+\+\+ ' \
        | grep -i -E -f "$PATTERNS" || true)"
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "private-identifiers: personal identifier added by an outgoing commit (even if removed later)" >&2
        found=1
    fi
}

# 範囲内の各コミットで足した・名前を変えた・写したファイルの名前（中身の無いファイルやバイナリは
# パッチの見出しに名前が出ないので、名前の一覧として別に見る。-z で非 ASCII の名前の引用を避ける）
check_paths() {
    local names hits
    names="$(git log --diff-merges=first-parent --format= --name-only -z --diff-filter=ACR "$@" | tr '\0' '\n')" \
        || fail "git log --name-only failed: $*"
    hits="$(printf '%s\n' "$names" | grep -i -E -f "$PATTERNS" || true)"
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "private-identifiers: personal identifier in a file name added by an outgoing commit" >&2
        found=1
    fi
}

# 範囲内の各コミットのメッセージと作成者・コミッタ
check_commits() {
    local log hits
    log="$(git log --format='commit %h%n%an <%ae>%n%cn <%ce>%n%B' "$@")" || fail "git log failed: $*"
    hits="$(printf '%s\n' "$log" | grep -n -i -E -f "$PATTERNS" || true)"
    if [ -n "$hits" ]; then
        echo "$hits" >&2
        echo "private-identifiers: personal identifier found in commit messages or authors" >&2
        found=1
    fi
}

case "${1:-}" in
pre-push)
    while read -r local_ref local_sha remote_ref remote_sha; do
        [ "$local_sha" = "$ZERO" ] && continue          # ref の削除は検査しない
        check_tree "$local_sha"
        if [ "$remote_sha" = "$ZERO" ]; then
            set -- "$local_sha" --not --remotes          # 新しい ref: どの remote にも無いコミット
        else
            set -- "$remote_sha..$local_sha"
        fi
        check_commits "$@"
        check_patches "$@"
        check_paths "$@"
    done
    ;;
tree)
    [ -n "${2:-}" ] || fail "usage: $0 tree <rev>"
    check_tree "$2"
    ;;
text)
    shift
    rc=0
    if [ "$#" -eq 0 ]; then                            # bash 3.2 は set -u で空の "$@" を嫌う
        grep -n -i -E -f "$PATTERNS" >&2 || rc=$?
    else
        grep -n -i -E -f "$PATTERNS" "$@" >&2 || rc=$?
    fi
    case "$rc" in
    0) echo "private-identifiers: personal identifier found in the text" >&2; found=1 ;;
    1) ;;
    *) fail "could not read the text (grep exit $rc)" ;;
    esac
    ;;
*)
    fail "usage: $0 pre-push | tree <rev> | text [file...]"
    ;;
esac

if [ "$found" -ne 0 ]; then
    echo "private-identifiers: refused. Remove the identifiers above and retry." >&2
    exit 1
fi
exit 0
