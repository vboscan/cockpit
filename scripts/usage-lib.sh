#!/usr/bin/env bash
# Shared by claude-run.sh, usage-session.sh, usage-report.sh, explain-iteration.sh.
# The ledger is a JSONL file OUTSIDE git ($RALPH_USAGE_LEDGER): per-gate rows land
# after the confirm marker froze the tree, so committing them would re-trip the
# "tree moved" refusal every iteration — and it is telemetry, not a design record.
# Weights (the brief's, README "Hot path"): cache-read 0.1×, cache-write 2× (1h TTL),
# output 5×, input 1×. Budget by weighted tokens, never raw counts.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph-config.sh"
: "${RALPH_USAGE_LEDGER:=$HOME/.config/${RALPH_PROJECT_NAME}/usage.jsonl}"
: "${RALPH_W_INPUT:=1}" "${RALPH_W_CACHE_READ:=0.1}" "${RALPH_W_CACHE_WRITE:=2}" "${RALPH_W_OUTPUT:=5}"
# usage_py <python3 args…> — python with the ledger path and the weights in its
# environment, and only there. Nothing is exported: the scripts that source
# this run the project's own suite (ralph-iterate's suite_green and red check),
# and an exported ledger path reaches every test in it — a fixture's rows land
# on the real ledger and its assertions on its own HOME fail (claude_sandbox,
# 2026-10-11: PR #14's branch was parked twice for that).
usage_py() {
  RALPH_USAGE_LEDGER="$RALPH_USAGE_LEDGER" RALPH_W_INPUT="$RALPH_W_INPUT" RALPH_W_CACHE_READ="$RALPH_W_CACHE_READ" \
  RALPH_W_CACHE_WRITE="$RALPH_W_CACHE_WRITE" RALPH_W_OUTPUT="$RALPH_W_OUTPUT" python3 "$@"
}

# usage_append <json-object>: append one row; never fails the caller.
usage_append() {
  mkdir -p "$(dirname "${RALPH_USAGE_LEDGER}")" 2>/dev/null || { echo "warn: usage ledger dir unwritable" >&2; return 0; }
  printf '%s\n' "$1" >> "${RALPH_USAGE_LEDGER}" 2>/dev/null || echo "warn: usage ledger write failed" >&2
  return 0
}

# transcript_dirs <cwd>: where the client keeps the transcripts of sessions run in
# <cwd>: ~/.claude/projects/<cwd with every non-alphanumeric character as '-'>
# (2.1.289: `/`, `.` and `_` alike), then its lower-cased twin for clients that
# fold the case. The twin is left out when it is the same directory: with an
# all-lowercase path every transcript was summed twice (/home/dev/catatumbo and
# CI temp dirs, 2026-09-30).
transcript_dirs() {
  local proj="${RALPH_TRANSCRIPT_DIR:-$HOME/.claude/projects}" enc
  enc="$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"
  echo "${proj}/${enc}"
  [[ "${enc,,}" == "${enc}" ]] || echo "${proj}/${enc,,}"
}
