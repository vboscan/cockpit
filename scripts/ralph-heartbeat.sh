#!/usr/bin/env bash
# ANCHOR: ralph-heartbeat — supervises scripts/ralph-driver.sh across usage-limit
# outages. The driver exits when the pool is exhausted (exit 2); this script
# waits for the pool to come back and relaunches it, so an outage costs one
# iteration instead of the whole overnight run.
#
#   scripts/ralph-heartbeat.sh [-p <promise>] [-n <max-iterations>]
#
# Flags are passed straight through to the driver.
#
# Why a probe and not banner parsing: no supported CLI or API surface exposes
# Max-pool status headlessly (/usage is TUI-only, verified 2026-07-24). The
# only reliable signal is to make a real request and see whether it lands, so
# the probe is a throwaway prompt on the implementer model — representative by
# construction, and a probe that fails while limited costs nothing.
#
# Run it in place of the driver, inside its own tmux, named per project so
# several kits on one box do not collide (RALPH_TMUX_SESSION, default
# ralph-<project>; scripts/ralph-config.sh):
#   tmux new -As ralph-<project> 'scripts/ralph-heartbeat.sh'
# Cancel the same way as the driver: touch ralph/STOP.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/ralph-config.sh
. "$REPO_ROOT/scripts/ralph-config.sh" # RALPH_TMUX_SESSION, RALPH_ITER_SESSION, RALPH_MODEL
DRIVER="$REPO_ROOT/scripts/ralph-driver.sh"
STOP_FILE="$REPO_ROOT/ralph/STOP"
STATE_DIR="$REPO_ROOT/.ralph"
LOCK_FILE="$STATE_DIR/heartbeat.lock"
RELAUNCH_LOG="$STATE_DIR/relaunches.log"

MODEL="${RALPH_MODEL:-claude-opus-5-5}"
PROBE_INTERVAL="${RALPH_PROBE_INTERVAL:-600}"  # 10 min: pool resets land within
                                               # one interval without polling hard
PROBE_TIMEOUT="${RALPH_PROBE_TIMEOUT:-120}"
MAX_RELAUNCHES="${RALPH_MAX_RELAUNCHES:-3}"    # per rolling 24h
WINDOW=86400

# Driver exit codes — must match the contract documented in ralph-driver.sh.
EXIT_OK=0 EXIT_MERIT=1 EXIT_LIMIT=2

notify() { "$REPO_ROOT/scripts/notify.sh" "$1" || true; } # non-blocking contract
say() { echo "$(date -Is) heartbeat: $*"; }

# Only one supervisor per repo, or two loops race for the same worktree.
# The lock is held for the whole run and released when this shell exits.
mkdir -p "$STATE_DIR"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  say "another heartbeat already holds $LOCK_FILE — refusing to start a second loop"
  exit 1
fi

# A live iteration session means a driver is already running (possibly one
# started by hand). Supervising it from here would double-drive the worktree.
if tmux has-session -t "$RALPH_ITER_SESSION" 2>/dev/null; then
  say "tmux session '$RALPH_ITER_SESSION' is live — a driver is already running; refusing to start"
  exit 1
fi

# The sentinel relaunches this script under RALPH_TMUX_SESSION; a heartbeat
# started by hand under some other name still works, but the sentinel would
# then not find it by name — say so once rather than let the two disagree.
_here=$(tmux display-message -p '#S' 2>/dev/null || true)
if [[ -n $_here && $_here != "$RALPH_TMUX_SESSION" ]]; then
  say "running in tmux session '$_here'; the configured name is '$RALPH_TMUX_SESSION' (RALPH_TMUX_SESSION)"
fi
unset _here

# relaunch_budget_left — how many relaunches remain in the rolling window.
# Bounds reset-boundary thrash: a pool that grants a few minutes and dies
# again would otherwise burn partial iterations unattended all night.
relaunch_budget_left() {
  local now cutoff used=0
  now=$(date +%s)
  cutoff=$((now - WINDOW))
  if [[ -f $RELAUNCH_LOG ]]; then
    # Keep only in-window stamps, so the log cannot grow without bound.
    awk -v c="$cutoff" '$1 > c' "$RELAUNCH_LOG" >"$RELAUNCH_LOG.tmp" 2>/dev/null \
      && mv "$RELAUNCH_LOG.tmp" "$RELAUNCH_LOG"
    used=$(wc -l <"$RELAUNCH_LOG")
  fi
  echo $((MAX_RELAUNCHES - used))
}

record_relaunch() { date +%s >>"$RELAUNCH_LOG"; }

# pool_available — one throwaway request on the implementer model. Success is
# a normal exit AND non-empty output: `claude -p` can exit 0 while printing the
# limit banner, so exit status alone would read a limited pool as healthy.
pool_available() {
  local out
  out=$(timeout "$PROBE_TIMEOUT" claude -p --model "$MODEL" 'reply with OK' 2>&1)
  local rc=$?
  ((rc == 0)) || return 1
  grep -qE "hit your (session|usage) limit|/upgrade to increase" <<<"$out" && return 1
  [[ -n ${out//[[:space:]]/} ]]
}

# wait_for_pool — probe until the pool answers, STOP appears, or the caller
# gives up. Returns 1 if the wait was cancelled rather than satisfied.
wait_for_pool() {
  local waited=0
  while :; do
    [[ -e $STOP_FILE ]] && { say "ralph/STOP appeared while waiting — stopping"; return 1; }
    if pool_available; then
      say "probe passed after ${waited}s — pool is back"
      return 0
    fi
    sleep "$PROBE_INTERVAL"
    waited=$((waited + PROBE_INTERVAL))
    say "probe failed (${waited}s waiting on the pool)"
  done
}

say "supervising $DRIVER (probe: $MODEL every ${PROBE_INTERVAL}s, max $MAX_RELAUNCHES relaunches/24h)"

while :; do
  [[ -e $STOP_FILE ]] && { say "ralph/STOP present — stopping"; exit 0; }

  "$DRIVER" "$@"
  rc=$?

  case $rc in
    "$EXIT_OK")
      say "driver finished cleanly — nothing left to supervise"
      exit 0
      ;;
    "$EXIT_MERIT")
      say "driver stopped on merit (exit 1) — a human needs to look; not relaunching"
      exit 1
      ;;
    "$EXIT_LIMIT")
      left=$(relaunch_budget_left)
      if ((left <= 0)); then
        say "usage-limit exit but the ${MAX_RELAUNCHES}-relaunch/24h budget is spent — stopping"
        notify "ralph: usage limits exhausted the relaunch budget ($MAX_RELAUNCHES/24h) — loop stopped, needs a human"
        exit 1
      fi
      say "usage-limit exit — waiting for the pool ($left relaunch(es) left in the window)"
      wait_for_pool || exit 0
      # A limit death kills the session mid-edit, so the tree is dirty by
      # construction and the driver's first act — preflight — would reject it,
      # exiting on merit and stopping the very recovery this supervisor exists
      # to perform (observed 2026-07-25 01:15). Park the sub-checkpoint residue
      # so preflight sees a clean tree; `checkpoint(...)` commits survive and
      # the relaunched iteration resumes from them (ralph/PROMPT.md step 2).
      if ! park_out=$("$REPO_ROOT/scripts/park-wip.sh" limit-recovery 2>&1); then
        say "could not park the residue before relaunching — stopping: $park_out"
        notify "ralph: pool recovered but parking the interrupted iteration failed — loop stopped, needs a human"
        exit 1
      fi
      say "$park_out"
      record_relaunch
      # info: the heartbeat handled it; an operator has nothing to explain.
      RALPH_NOTIFY_KIND=info notify "ralph: pool recovered — relaunching the loop ($((left - 1)) relaunch(es) left today)"
      ;;
    *)
      # Unknown code: the contract has drifted, or the driver died on a signal.
      # Fail safe — stop and tell the owner rather than relaunch blindly.
      say "driver exited $rc, which is outside the contract — stopping"
      notify "ralph: driver exited with unexpected code $rc — loop stopped, needs a human"
      exit 1
      ;;
  esac
done
