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
exec gh "$@"
