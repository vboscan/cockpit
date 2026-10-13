#!/usr/bin/env bash
# Behavioural tests for the tmux session names scripts/ralph-config.sh derives.
#
# Two kits on one box used to share the literal names `ralph` and `ralph-iter`:
# the heartbeat refuses to start while the iteration session exists, and the
# sentinel relaunches the heartbeat by name, so the second project's loop
# could not start until the first one finished (2026-09-30). The names are
# now derived from RALPH_PROJECT_NAME. These tests pin the properties that
# make side-by-side loops work: two projects get two names, the environment
# still wins, and a name tmux would reject never reaches tmux.
#
# Run: scripts/test-session-names.sh   (exit 0 = all assertions passed)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_SH="$REPO_ROOT/scripts/ralph-config.sh"

pass=0
fail=0
ok()  { printf '  ok   — %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL — %s: %s\n' "$1" "$2"; fail=$((fail + 1)); }

# names <repo-dir> [VAR=value ...] — source the config for a fake project
# rooted at <repo-dir> in a clean subshell and print the three names.
names() {
  local root=$1; shift
  env -i HOME="$HOME" PATH="$PATH" "$@" bash -c '
    RALPH_REPO_ROOT="$1"
    . "$2"
    printf "%s %s %s\n" "$RALPH_TMUX_SESSION" "$RALPH_ITER_SESSION" "$RALPH_SENTINEL_SESSION"
  ' _ "$root" "$CONFIG_SH"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/catatumbo" "$tmp/habitus" "$tmp/My.Repo"

echo "session names — two projects on one box"

a=$(names "$tmp/catatumbo")
b=$(names "$tmp/habitus")
[[ $a == "ralph-catatumbo ralph-catatumbo-iter ralph-catatumbo-sentinel" ]] \
  && ok "derived from the project directory: $a" \
  || bad "derived from the project directory" "got '$a'"
[[ $a != "$b" ]] \
  && ok "two projects get two sets of names" \
  || bad "two projects get two sets of names" "both '$a'"

c=$(names "$tmp/My.Repo")
[[ $c == "ralph-my-repo ralph-my-repo-iter ralph-my-repo-sentinel" ]] \
  && ok "lower-cased, and characters tmux rejects become '-': $c" \
  || bad "lower-cased and sanitised" "got '$c'"

d=$(names "$tmp/catatumbo" RALPH_PROJECT_NAME=Catatumbo)
[[ $d == "$a" ]] \
  && ok "a capitalised RALPH_PROJECT_NAME yields the same names" \
  || bad "capitalised project name" "got '$d'"

e=$(names "$tmp/catatumbo" RALPH_TMUX_SESSION=loop-one)
[[ $e == "loop-one loop-one-iter loop-one-sentinel" ]] \
  && ok "RALPH_TMUX_SESSION from the environment wins and the others follow it" \
  || bad "environment override" "got '$e'"

f=$(names "$tmp/catatumbo" RALPH_ITER_SESSION=custom-iter)
[[ $f == "ralph-catatumbo custom-iter ralph-catatumbo-sentinel" ]] \
  && ok "RALPH_ITER_SESSION can be overridden on its own" \
  || bad "iter override" "got '$f'"

# The driver and heartbeat must take the name from the config, not a literal.
for s in ralph-driver.sh ralph-heartbeat.sh ralph-sentinel.sh; do
  if grep -v 'ralph-iterate\.sh' "$REPO_ROOT/scripts/$s" | grep -qE "ralph-iter|-t ralph |-s ralph |-t ralph$"; then
    bad "$s carries no literal session name" "found one"
  else
    ok "$s carries no literal session name"
  fi
done
grep -q 'RALPH_ITER_SESSION' "$REPO_ROOT/scripts/ralph-driver.sh" \
  && ok "the driver spawns RALPH_ITER_SESSION" \
  || bad "the driver spawns RALPH_ITER_SESSION" "no reference"
grep -q 'has-session -t "\$RALPH_ITER_SESSION"' "$REPO_ROOT/scripts/ralph-heartbeat.sh" \
  && ok "the heartbeat's already-running check uses RALPH_ITER_SESSION" \
  || bad "heartbeat already-running check" "still literal"

echo
echo "test-session-names: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
