#!/usr/bin/env bash
# gh の書き込み系操作（issue / comment / pr / release など）を、active アカウントが期待どおりの
# ときだけ通す番人。このプロジェクトは公開名義を 1 つに固定しているため、別アカウントからの
# 投稿は取り消せない事故になる（Issue の削除権限は相手側にある）。
# 使い方: Scripts/gh-guarded.sh issue create --repo owner/name --title ... --body-file ...
# 期待アカウントは env STACKNEST_GH_LOGIN で上書きできる（既定: shelfsmith）。
set -euo pipefail
EXPECTED="${STACKNEST_GH_LOGIN:-shelfsmith}"
# GITHUB_TOKEN / GH_TOKEN があると gh の active アカウントが無視されるので、判定前に外す
unset GITHUB_TOKEN GH_TOKEN
ACTUAL="$(gh api user --jq .login 2>/dev/null || true)"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "gh-guarded: active gh account is '${ACTUAL:-none}', expected '$EXPECTED'. Refusing: gh $*" >&2
  echo "gh-guarded: run 'gh auth switch --user $EXPECTED' and retry." >&2
  exit 1
fi
# 2026-10-01: 投稿の本文・タイトルに個人識別子（実名など）が無いことを確かめてから投稿する。
# 検査するもの:
#   - 引数すべて（--title / --body / -f などの直接の値）
#   - 引数が指すファイルの中身。引数そのもの・「キー=値」の値・「@パス」の形（gh api の -F key=@file）の
#     どれかが既存のファイルなら読む（--body-file・--notes-file・--input・gist のファイルなど、渡し方を問わない）
#   - 標準入力の本文（ファイル指定の位置の "-"、または "@-"）。一時ファイルに受けてから検査し、gh にはその
#     一時ファイルを渡す
# gh api の -F は「キー=値」の指定で、本文のファイル名ではない（値が @パスのときだけファイル）。
if [ "$#" -eq 0 ]; then exec gh; fi
CHECK="$(cd "$(dirname "$0")" && pwd)/check-private-identifiers.sh"
TEXT="$(mktemp -t gh-guarded-text)"
STDIN_BODY=""
cleanup() { rm -f "$TEXT"; [ -n "$STDIN_BODY" ] && rm -f "$STDIN_BODY"; return 0; }
trap cleanup EXIT
printf '%s\n' "$@" > "$TEXT"
SUB="$1"
# 標準入力を一度だけ一時ファイル STDIN_BODY に受ける（2 回目以降は同じファイル）。
# $(...) の中で呼ぶとサブシェルになり STDIN_BODY が残らない（後片付けから漏れる）ので、直接呼ぶ
capture_stdin() {
  if [ -z "$STDIN_BODY" ]; then
    STDIN_BODY="$(mktemp -t gh-guarded-body)"
    cat > "$STDIN_BODY"
  fi
}
# 既存のファイルなら中身を検査対象に足す
add_file() { [ -f "$1" ] && cat "$1" >> "$TEXT"; return 0; }
ARGS=()
prev=""
for a in "$@"; do
  # ファイルを取るオプションの直後の "-" は標準入力（gh api の -F は除く）
  if [ "$a" = "-" ]; then
    case "$prev" in
      --body-file|--notes-file|--input) capture_stdin; a="$STDIN_BODY" ;;
      -F) if [ "$SUB" != "api" ]; then capture_stdin; a="$STDIN_BODY"; fi ;;
    esac
  fi
  case "$a" in
    *=@-) capture_stdin; a="${a%@-}@$STDIN_BODY" ;;   # gh api -F key=@- （標準入力）
  esac
  add_file "$a"
  case "$a" in
    *=*)
      v="${a#*=}"
      add_file "$v"
      case "$v" in @*) add_file "${v#@}" ;; esac
      ;;
  esac
  ARGS+=("$a")
  prev="$a"
done
"$CHECK" text "$TEXT" || { echo "gh-guarded: refusing to post: gh $1 ${2:-}" >&2; exit 1; }
# exec で置き換えると後片付け（trap）が走らないので、gh を呼んでから終了コードを返す
rc=0
gh "${ARGS[@]}" || rc=$?
exit "$rc"
