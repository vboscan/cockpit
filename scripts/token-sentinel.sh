#!/usr/bin/env bash
# ANCHOR: token-sentinel — a stage that spends more than its cap is killed.
#
# The usage ledger (scripts/usage-lib.sh) records what each stage cost after
# it ran. This script reads the same transcript WHILE the stage runs, and ends
# the session the moment its weighted tokens pass the stage's cap: an
# accidental leak (a session re-reading a huge file every turn, a runaway
# fan-out, a loop that never idles) costs one stage, not a day's quota. It is
# a tripwire, not a budget: the caps sit well above what a healthy stage
# spends (ralph-config.sh), so a cap that fires means something is wrong, and
# the loop stops on merit so a human looks.
#
#   scripts/token-sentinel.sh cap   <stage>
#   scripts/token-sentinel.sh check <stage> <spec> <slice> <session-id> [--root <dir>]
#   scripts/token-sentinel.sh watch <stage> <spec> <slice> <session-id> [--root <dir>] -- <command…>
#   scripts/token-sentinel.sh report <stage> <spec> <slice> <spent> <cap>
#
#   cap     prints the stage's cap in weighted tokens (0 = none): RALPH_TOKEN_CAP_<STAGE>
#           (upper-case, every other character '_'), else RALPH_TOKEN_CAP.
#   check   reads the session's transcript once (the client writes
#           <transcripts>/<cwd>/<session-id>.jsonl as the session runs; --root
#           is that cwd, default the current directory). Prints SPENT= and CAP=.
#           Exit 0 under the cap, 4 over it — and then the breach is recorded:
#           a ledger row for the stage with "over_cap": true, and the owner
#           notified. The caller kills the session (scripts/ralph-driver.sh).
#   watch   runs the command, checks every RALPH_TOKEN_CAP_POLL seconds, and on
#           a breach kills the command's process tree, records it as `check`
#           does, and exits 4. Otherwise the command's exit code and output are
#           its own (scripts/claude-run.sh wraps every headless stage in this).
#   report  the breach message and notification, for a caller that found the
#           breach itself (claude-run.sh, from the result envelope).
#
# The spend is every assistant turn in the transcript, sub-agent turns included:
# they are spend. Weights are the ledger's (input 1, cache read 0.1, cache write
# 2, output 5). A missing transcript is a spend of 0, never an error: a session
# that has not started yet has not leaked.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/usage-lib.sh
. "$HERE/usage-lib.sh" # RALPH_TOKEN_CAP*, weights, transcript_dirs, usage_append

EXIT_CAP=4

usage() {
  echo "usage: $(basename "$0") cap <stage>" >&2
  echo "       $(basename "$0") check <stage> <spec> <slice> <session-id> [--root <dir>]" >&2
  echo "       $(basename "$0") watch <stage> <spec> <slice> <session-id> [--root <dir>] -- <command…>" >&2
  echo "       $(basename "$0") report <stage> <spec> <slice> <spent> <cap>" >&2
  exit 2
}

# stage_cap <stage> — RALPH_TOKEN_CAP_<STAGE> when set, else RALPH_TOKEN_CAP.
stage_cap() {
  local s="${1^^}" v
  v="RALPH_TOKEN_CAP_${s//[^A-Z0-9]/_}"
  if [[ -n ${!v-} ]]; then echo "${!v}"; else echo "${RALPH_TOKEN_CAP}"; fi
}

# transcript <root> <session-id> — the session's transcript, or nothing yet.
transcript() {
  local d
  while IFS= read -r d; do
    [[ -f "$d/$2.jsonl" ]] && { echo "$d/$2.jsonl"; return 0; }
  done < <(transcript_dirs "$1")
  return 0
}

# row <stage> <spec> <slice> <session-id> <transcript|""> <cap> — the ledger row
# for what the transcript holds so far, "over_cap" set against the cap. Prints
# the JSON; SPENT is read from it by the caller.
row() {
  usage_py - "$@" <<'PY'
import json, os, sys, time
stage, spec, slice_, sid, path, cap = sys.argv[1:7]
w = {k: float(os.environ["RALPH_W_" + k.upper()]) for k in ("input", "cache_read", "cache_write", "output")}
i = o = cr = cw = turns = 0; models = set()
if path:
    for line in open(path, errors="ignore"):
        if '"usage"' not in line: continue
        try: d = json.loads(line)
        except ValueError: continue
        if d.get("type") != "assistant": continue
        m = d.get("message") or {}; u = m.get("usage") or {}
        if not u: continue
        turns += 1; models.add(m.get("model", "?"))
        i += u.get("input_tokens", 0); o += u.get("output_tokens", 0)
        cr += u.get("cache_read_input_tokens", 0); cw += u.get("cache_creation_input_tokens", 0)
weighted = round(i * w["input"] + cr * w["cache_read"] + cw * w["cache_write"] + o * w["output"])
cap = int(cap)
print(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "spec": spec, "slice": slice_,
                  "stage": stage, "model": ",".join(sorted(models)) or "unknown", "input": i, "output": o,
                  "cache_read": cr, "cache_write": cw, "cost_usd": None, "duration_ms": None, "num_turns": turns,
                  "session_id": sid, "fixed_context_per_turn": round(cr / turns) if turns else 0,
                  "weighted": weighted, "cap": cap, "over_cap": bool(cap > 0 and weighted > cap), "exit": 4}))
PY
}

# report <stage> <spec> <slice> <spent> <cap> — say it, and tell the owner.
report() {
  local stage="$1" spec="$2" slice="$3" spent="$4" cap="$5" var msg
  var="RALPH_TOKEN_CAP_${stage^^}"; var="${var//[^A-Z0-9_]/_}"
  msg="ralph token sentinel: the ${stage} session for ${spec} ${slice} spent ${spent} weighted tokens, past its cap of ${cap} — killed, loop stopped. If this was real work, raise ${var} (or RALPH_TOKEN_CAP) in .ralph/config.sh; scripts/usage-report.sh shows what the stage normally costs."
  echo "${msg}" >&2
  "$HERE/notify.sh" -t "ralph token sentinel" "${msg}" >/dev/null 2>&1 || true
}

# breach <row-json> — record the breach: the ledger row, then the report.
breach() {
  local r="$1" spent
  usage_append "${r}"
  spent="$(printf '%s' "${r}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["weighted"])')"
  report "${stage}" "${spec}" "${slice}" "${spent}" "${cap}"
}

# over <row-json> — true when the row says over_cap
over() { [[ "$1" == *'"over_cap": true'* ]]; }

parse() { # <stage> <spec> <slice> <session-id> [--root <dir>] [-- cmd…]
  stage="${1-}"; spec="${2-}"; slice="${3-}"; sid="${4-}"; root="$PWD"
  [[ -n "$stage" && -n "$spec" && -n "$slice" && -n "$sid" ]] || usage
  shift 4
  while (($#)); do
    case "$1" in
      --root) root="${2-}"; [[ -n "$root" ]] || usage; shift 2 ;;
      --) shift; break ;;
      *) usage ;;
    esac
  done
  cmd=("$@")
  cap="$(stage_cap "$stage")"
  [[ "$cap" =~ ^[0-9]+$ ]] || { echo "token-sentinel: the cap for ${stage} is not a number: ${cap}" >&2; exit 2; }
}

# kill_tree <pid> — the process and every descendant, children first.
kill_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
}

cmd_check() {
  parse "$@"
  local f r
  f="$(transcript "$root" "$sid")"
  r="$(row "$stage" "$spec" "$slice" "$sid" "$f" "$cap")"
  echo "SPENT=$(printf '%s' "${r}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["weighted"])')"
  if ((cap > 0)); then echo "CAP=${cap}"; else echo "CAP=none"; fi
  over "${r}" || return 0
  breach "${r}"
  return $EXIT_CAP
}

cmd_watch() {
  parse "$@"
  ((${#cmd[@]})) || usage
  local poll="${RALPH_TOKEN_CAP_POLL:-15}" pid f r t=0 rc
  [[ "$poll" =~ ^[0-9]+$ && "$poll" -ge 1 ]] || poll=1 # whole seconds, at least one
  "${cmd[@]}" <&0 & pid=$!
  trap 'kill_tree "$pid"' TERM INT
  # Liveness every second so the command's exit is seen promptly; the transcript
  # every $poll seconds. No cap: nothing to read, just wait.
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1; t=$((t + 1))
    ((cap > 0 && t % poll == 0)) || continue
    f="$(transcript "$root" "$sid")"; [[ -n "$f" ]] || continue
    r="$(row "$stage" "$spec" "$slice" "$sid" "$f" "$cap")"
    over "${r}" || continue
    kill_tree "$pid"
    wait "$pid" 2>/dev/null
    breach "${r}"
    exit $EXIT_CAP
  done
  wait "$pid"; rc=$?
  exit "$rc"
}

case "${1-}" in
  cap) [[ -n "${2-}" ]] || usage; stage_cap "$2" ;;
  check) shift; cmd_check "$@" ;;
  watch) shift; cmd_watch "$@" ;;
  report) shift; [[ $# -eq 5 ]] || usage; report "$@" ;;
  *) usage ;;
esac
