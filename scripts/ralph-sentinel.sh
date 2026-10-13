#!/usr/bin/env bash
# ANCHOR: ralph-sentinel — watches for scripts/ralph-heartbeat.sh dying silently.
#
# Observed 2026-08-07 and 2026-08-09: the heartbeat process (and its tmux
# session) vanished mid-supervision with no line from any of its documented
# exit paths (clean/merit/budget-spent/unexpected-code/STOP) and no evidence
# of a reboot, OOM, or crash reachable from this box (no journalctl/dmesg
# access). Root cause unconfirmed — this is a mitigation, not a fix.
#
# REPO_ROOT is PINNED by config rather than derived from BASH_SOURCE (unlike
# the rest of this directory): this script's whole job is to keep polling the
# ONE live devbox checkout no matter where its own copy is invoked from — a
# worktree or a copy elsewhere must not silently retarget it. The pin moved
# from a literal path to `RALPH_SENTINEL_REPO_ROOT` when this was extracted
# into the kit; the requirement is unchanged, so an unset pin exits rather
# than falling back to a derived root. Guessing here means supervising the
# wrong checkout, which looks identical to working.
#
# Usage: run detached in its own tmux session, forever (one per project;
# RALPH_SENTINEL_SESSION, default ralph-<project>-sentinel):
#   tmux new -d -s ralph-<project>-sentinel 'scripts/ralph-sentinel.sh'
# Stand down the same way the loop itself does: touch ralph/STOP in the repo.
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph-config.sh"

REPO_ROOT="${RALPH_SENTINEL_REPO_ROOT:-}"
if [ -z "$REPO_ROOT" ]; then
  echo "ralph-sentinel: RALPH_SENTINEL_REPO_ROOT is unset — set it to the absolute" >&2
  echo "  path of the live checkout in .ralph/config.sh. Refusing to derive it." >&2
  exit 2
fi
LOCK_FILE="$REPO_ROOT/.ralph/heartbeat.lock"
STOP_FILE="$REPO_ROOT/ralph/STOP"
# One log per project: two sentinels on one box must not interleave.
LOG_FILE="${RALPH_SENTINEL_LOG:-$HOME/.local/ralph-ops/sentinel-${RALPH_PROJECT_NAME}.log}"
CHECK_INTERVAL="${RALPH_SENTINEL_INTERVAL:-300}" # 5 min

mkdir -p "$(dirname "$LOG_FILE")"
say() { echo "$(date -Is) sentinel: $*" | tee -a "$LOG_FILE"; }

say "starting, checking every ${CHECK_INTERVAL}s (lock: $LOCK_FILE)"

while :; do
  if [[ -e "$STOP_FILE" ]]; then
    say "ralph/STOP present — standing down, not supervising"
    sleep "$CHECK_INTERVAL"
    continue
  fi

  # Authoritative liveness check: is a heartbeat holding the flock? (same test
  # used to diagnose the two prior silent deaths by hand).
  held=1
  if [[ -e "$LOCK_FILE" ]]; then
    flock -n "$LOCK_FILE" -c true 2>/dev/null && held=0
  else
    held=0 # no lock file yet means nothing has ever started it
  fi

  if [[ $held -eq 0 ]]; then
    say "heartbeat lock is free — loop is dead, relaunching"
    tmux kill-session -t "$RALPH_TMUX_SESSION" 2>/dev/null || true
    if (cd "$REPO_ROOT" && tmux new -d -s "$RALPH_TMUX_SESSION" -e RALPH_MAX_RELAUNCHES=12 'scripts/ralph-heartbeat.sh'); then
      say "relaunched scripts/ralph-heartbeat.sh in tmux session '$RALPH_TMUX_SESSION'"
      "$REPO_ROOT/scripts/notify.sh" -t "ralph sentinel" "found the heartbeat dead and relaunched it" || true
    else
      say "relaunch failed — tmux new-session returned nonzero"
      "$REPO_ROOT/scripts/notify.sh" -t "ralph sentinel" "found the heartbeat dead and FAILED to relaunch it — needs a human" || true
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
