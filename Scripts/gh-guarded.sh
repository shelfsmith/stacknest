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
# 引数すべてと、--body-file / -F で渡したファイルの中身を検査する（- は標準入力を一時ファイルに受ける）。
CHECK="$(cd "$(dirname "$0")" && pwd)/check-private-identifiers.sh"
TEXT="$(mktemp -t gh-guarded-text)"
STDIN_BODY=""
trap 'rm -f "$TEXT" ${STDIN_BODY:+"$STDIN_BODY"}' EXIT
printf '%s\n' "$@" > "$TEXT"
ARGS=()
expect_file=0
for a in "$@"; do
  if [ "$expect_file" -eq 1 ]; then
    expect_file=0
    if [ "$a" = "-" ]; then
      STDIN_BODY="$(mktemp -t gh-guarded-body)"
      cat > "$STDIN_BODY"
      a="$STDIN_BODY"
    fi
    cat "$a" >> "$TEXT"
  else
    case "$a" in
      --body-file|-F) expect_file=1 ;;
      --body-file=*) cat "${a#--body-file=}" >> "$TEXT" ;;
    esac
  fi
  ARGS+=("$a")
done
"$CHECK" text "$TEXT" || { echo "gh-guarded: refusing to post: gh $1 ${2:-}" >&2; exit 1; }
exec gh "${ARGS[@]}"
