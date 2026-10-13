#!/usr/bin/env bash
# Functions preflight.sh runs and scripts/test-preflight-lib.sh exercises. Sourced,
# never executed — the same split as pane-busy.sh, and for the same reason: a
# check that exists only inline in preflight.sh cannot be tested, and the first
# version of the stale-branch check killed preflight on every healthy tree.

# stale_branches <repo> — local branches whose upstream is gone, space-separated,
# empty when none. A merged branch is dead (ralph/PROMPT.md step 7; LESSONS §7):
# origin deletes the branch at merge, so "upstream gone" is what a merged branch
# looks like the morning after, and a commit pushed to it recreates a branch
# nobody watches. Must be safe under `set -euo pipefail` in the healthy (empty)
# case: awk exits 0 with no matches, unlike grep.
stale_branches() {
  git -C "$1" branch -vv 2>/dev/null | awk '/^[* ] [^ ]+ +[0-9a-f]+ \[[^]]*: gone\]/ {print $1 == "*" ? $2 : $1}' | tr '\n' ' ' | sed 's/ $//' || true
}
