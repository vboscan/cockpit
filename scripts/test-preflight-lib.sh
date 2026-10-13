#!/usr/bin/env bash
# Behavioural tests for preflight-lib.sh (the stale-branch check of ralph/PROMPT.md step 7).
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0; root="$(mktemp -d)"; trap 'rm -rf "${root}"' EXIT
# shellcheck source=/dev/null
. "${KIT_SCRIPTS}/preflight-lib.sh"

new_repo() { local d="${root}/$1"; mkdir -p "${d}"; git init -q --bare "${d}/remote.git"; git init -q "${d}/repo"
  ( cd "${d}/repo" && git config user.email t@x && git config user.name t && git remote add origin "${d}/remote.git" \
    && git commit -q --allow-empty -m init && git branch -M main && git push -q -u origin main ); echo "${d}/repo"; }
check() { # <name> <want> <got>
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "  ok  — $1"
  else fail=$((fail+1)); echo "  FAIL — $1"; echo "         want '$2'; got '$3'"; fi; }

echo "preflight-lib.sh"
r="$(new_repo clean)"
check "only main, tracking → nothing stale" "" "$(stale_branches "$r")"

r="$(new_repo merged)"
( cd "$r" && git checkout -qb docs/thing && git commit -q --allow-empty -m work && git push -q -u origin docs/thing \
  && git checkout -q main && git push -q origin --delete docs/thing && git fetch -q --prune origin )
check "branch whose remote was deleted → listed" "docs/thing" "$(stale_branches "$r")"

( cd "$r" && git checkout -q docs/thing )
check "…also when it is the checked-out branch" "docs/thing" "$(stale_branches "$r")"

( cd "$r" && git checkout -q main && git checkout -qb local-only && git checkout -q main )
check "a branch with no upstream at all is not stale" "docs/thing" "$(stale_branches "$r")"

# The regression the first version shipped: under set -e -o pipefail the healthy case must not exit.
r="$(new_repo strict)"
out="$(bash -c 'set -euo pipefail; . "$1/preflight-lib.sh"; s="$(stale_branches "$2")"; echo "survived:[${s}]"' _ "${KIT_SCRIPTS}" "$r" 2>&1)"
check "healthy tree under set -euo pipefail survives the assignment" "survived:[]" "$out"

echo "  ${pass} passed, ${fail} failed"; [[ $fail -eq 0 ]]
