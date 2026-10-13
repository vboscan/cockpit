#!/usr/bin/env bash
# ANCHOR: ralph-driver — fresh-session-per-iteration Ralph loop driver.
# Replaces the ralph-loop plugin (one ever-growing session; retired 2026-07-21,
# see PROGRESS.md). One cycle = spawn a fresh remote-controlled Claude session
# (scripts/claude-session.sh), send the iteration prompt, wait for the
# iteration to finish, kill the session. Before the session, the coordinator
# script runs the front of the iteration (scripts/ralph-iterate.sh): the
# session is the implementer, and starts where the hand-off says. Context never carries between
# iterations; state lives in PROGRESS.md/git (ralph/PROMPT.md doctrine).
#
#   scripts/ralph-driver.sh [-p <promise>] [-n <max-iterations>]
#
#   -p  phase completion promise to stop on (default ALL_SPECS_DONE;
#       Phase 1 uses DESIGN_GATE_REACHED — see ralph/PROMPT.md "Loop driver")
#   -n  max iterations before stopping (default 25)
#
# Cancel any time: touch ralph/STOP. Per-iteration wall-clock ceiling:
# RALPH_ITER_TIMEOUT seconds (default 7200); minimum iteration floor
# RALPH_ITER_FLOOR seconds (default 300) — idle-polling only starts after
# the floor, and idle must hold for IDLE_NEED consecutive polls before the
# session is considered done. Implementer model: RALPH_MODEL (default
# claude-opus-5-5 — AGENTS.md rule 14).
# Completion is judged by GIT STATE (origin/main advancing), never screen
# text; the pane is scraped only for the promise string, the RC URL, the
# busy/idle evidence (see pane_busy), and the usage-limit banner (see
# pane_limited). When an iteration ends, the pane is snapshotted to
# .ralph/logs/iter-N-pane.txt (gitignored) for post-mortems.
# The session is launched with a --session-id, and every RALPH_TOKEN_CAP_POLL
# seconds its transcript is read (scripts/token-sentinel.sh check): past
# RALPH_TOKEN_CAP_IMPLEMENT weighted tokens the session is killed and the loop
# stops on merit (`token-cap`) — a leaking iteration costs one iteration.
# Run inside its own tmux so it survives SSH drops (the heartbeat does this
# for you; see scripts/ralph-heartbeat.sh). The iteration session is named
# RALPH_ITER_SESSION (scripts/ralph-config.sh, per project).
#
# EXIT CODE CONTRACT — scripts/ralph-heartbeat.sh supervises this script and
# branches on these. Changing them changes the supervisor's behaviour:
#   0  loop finished on its own terms (promise reached, STOP file, max iters)
#   1  merit stop — a human must look (preflight fail, spawn fail, 2-strike
#      breaker, prompt never started). The supervisor does NOT relaunch.
#   2  usage-limit exit — quota, not merit. The supervisor waits for the pool
#      to recover and relaunches. Never counted against the 2-strike breaker.
# Any other code is treated by the supervisor as unknown and stops the loop.
#
# UNDER AN OPERATOR (scripts/ralph-operator.sh): the iteration's link goes to
# the operator's journal, not to the owner, while the operator's session is up;
# every exit, merge and no-merge is journalled with its reason
# (scripts/operator-lib.sh). With no operator, nothing here changes.
set -uo pipefail

EXIT_OK=0 EXIT_MERIT=1 EXIT_LIMIT=2

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/ralph-config.sh
. "$REPO_ROOT/scripts/ralph-config.sh" # RALPH_ITER_SESSION, RALPH_MODEL
# shellcheck source=scripts/operator-lib.sh
. "$REPO_ROOT/scripts/operator-lib.sh" # op_event, op_live
SESSION_SH="$REPO_ROOT/scripts/claude-session.sh"
STOP_FILE="$REPO_ROOT/ralph/STOP"
LOG_DIR="$REPO_ROOT/.ralph/logs"
mkdir -p "$LOG_DIR" # snapshots and the sentinel's last word land here
MODEL="${RALPH_MODEL:-claude-opus-5-5}"
TIMEOUT="${RALPH_ITER_TIMEOUT:-7200}"
FLOOR="${RALPH_ITER_FLOOR:-300}"
POLL="${RALPH_ITER_POLL:-30}" # seconds between pane checks; a test shortens it
CAP_POLL="${RALPH_TOKEN_CAP_POLL:-15}" # seconds between transcript reads
IDLE_NEED=3
PROMISE="ALL_SPECS_DONE"
MAX_ITERS=25
PROMPT='Run one iteration per ralph/PROMPT.md.'

while getopts 'p:n:' o; do
  case $o in
    p) PROMISE=$OPTARG ;;
    n) MAX_ITERS=$OPTARG ;;
    *) echo "usage: $(basename "$0") [-p promise] [-n max-iterations]" >&2; exit 2 ;;
  esac
done

notify() { "$REPO_ROOT/scripts/notify.sh" "$1" || true; } # non-blocking contract
# A quota yield is the heartbeat's to handle: journalled as info, for the record.
notify_info() { RALPH_NOTIFY_KIND=info "$REPO_ROOT/scripts/notify.sh" "$1" || true; }

# Why the driver exited, for the operator's journal. Set before each exit that
# an operator must tell apart; the code alone does not (0 is both "every spec is
# done" and "the front stopped for the owner").
why="" iter=0
trap 'op_event driver-exit "rc=$? iter=$iter${why:+ $why}"' EXIT

# Timestamp every driver line. Iterations shrink as a shared 5-hour usage
# window drains (PROGRESS.md 2026-07-24), and that trend is only visible if
# each iteration's start/end/elapsed is on disk.
say() { echo "$(date -Is) $*"; }

main_rev() { git -C "$REPO_ROOT" ls-remote origin -h refs/heads/main 2>/dev/null | cut -f1; }

# pane_limited lives in scripts/pane-busy.sh (sourced below) so it can be
# tested — a private copy here is why the weekly-limit banner went unnoticed.

# kill_tree <pid> — kill a process and every descendant, children first.
# Used to reap tools the iteration spawned (notably `agy`, which outlives the
# session that dispatched it). An orphaned agy keeps writing to the worktree
# between iterations, so the next iteration would start on a moving tree.
kill_tree() {
  local pid=$1 child
  for child in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$child"; done
  kill -TERM "$pid" 2>/dev/null || true
}

# reap_session_tools <tmux-session> — kill the session's pane process tree
# before the session itself goes away, while the parent links still exist.
reap_session_tools() {
  local pane_pid
  pane_pid=$(tmux list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1)
  [[ -n $pane_pid ]] || return 0
  local child
  for child in $(pgrep -P "$pane_pid" 2>/dev/null); do kill_tree "$child"; done
}

# pane_busy — decides whether an iteration is still working. Extracted to
# scripts/pane-busy.sh (with scripts/test-pane-busy.sh pinning the busy/idle
# fixtures) after two healthy iterations were misread as idle and killed
# 2026-07-26; sourced here so the driver and the tests share one definition.
# shellcheck source=scripts/pane-busy.sh
source "$REPO_ROOT/scripts/pane-busy.sh"

# snapshot <iter> <reason> — dump pane + scrollback so the next failure is
# diagnosable from disk
snapshot() {
  mkdir -p "$LOG_DIR"
  {
    echo "# iter $1 ended: $2 ($(date -Is), elapsed ${elapsed}s)"
    tmux capture-pane -t "$sess" -p -S -200
  } >"$LOG_DIR/iter-$1-pane.txt" 2>/dev/null || true
}

no_progress=0
for ((iter = 1; iter <= MAX_ITERS; iter++)); do
  [[ -e $STOP_FILE ]] && { why=stop-file; notify "ralph: stopped (ralph/STOP present) before iter $iter"; exit $EXIT_OK; }

  # Same hazard the supervisor already handles for limit deaths (see the park
  # before relaunch in ralph-heartbeat.sh), but a ceiling kill happens INSIDE
  # this loop and never reaches the supervisor: the session dies mid-edit, the
  # tree is dirty by construction, and preflight then merit-stops the whole loop
  # on the next pass — a healthy loop killed by its own timeout (observed
  # 2026-07-30 05:10, two consecutive ceiling deaths on spec 06 slice 4d).
  # Park the residue so preflight sees a clean tree; `checkpoint(...)` commits
  # survive and the next iteration resumes from them (ralph/PROMPT.md step 2).
  if [[ -n $(git -C "$REPO_ROOT" status --porcelain 2>/dev/null) ]]; then
    if ! park_out=$("$REPO_ROOT/scripts/park-wip.sh" "iter-${iter}-residue" 2>&1); then
      why=park
      notify "ralph: could not park the interrupted iteration's residue — loop stopped, needs a human"
      say "park failed before iter $iter: $park_out"
      exit $EXIT_MERIT
    fi
    say "$park_out"
  fi

  # The front of the iteration is the coordinator's (scripts/ralph-iterate.sh,
  # docs/coordinator-split.md): preflight, the spec, the branch, red observed
  # and committed, the plan review. The session below starts where its hand-off
  # says. The front notifies its own stops, so they are not notified twice.
  # The design-gate phase (-p DESIGN_GATE_REACHED) has no spec to prepare: it
  # keeps the bare prompt and runs preflight itself.
  if [[ $PROMISE == ALL_SPECS_DONE ]]; then
    "$REPO_ROOT/scripts/ralph-iterate.sh" front; front=$?
    why="front=$front"
    case $front in
      0) PROMPT=$(sed -n 's/^PROMPT=//p' "$REPO_ROOT/.ralph/handoff" 2>/dev/null)
         [[ $PROMPT == 'Run one iteration per'* ]] \
           || { why="front=0 no-handoff"; notify "ralph: the front left no hand-off (iter $iter) — loop stopped"; exit $EXIT_MERIT; } ;;
      10) why="front=10 promise"; notify "ralph: completion promise '$PROMISE' reached at iter $iter — loop done"; exit $EXIT_OK ;;
      11) say "iter $iter: the front stopped for the owner — loop done until they act"; exit $EXIT_OK ;;
      2) say "iter $iter: usage limit in the front — yielding to the supervisor"; exit $EXIT_LIMIT ;;
      *) say "iter $iter: the front failed (exit $front) — loop stopped"; exit $EXIT_MERIT ;;
    esac
  else
    "$REPO_ROOT/scripts/preflight.sh" || { why=preflight; notify "ralph: preflight FAILED — loop stopped at iter $iter"; exit $EXIT_MERIT; }
  fi

  why=""
  start_rev=$(main_rev)
  say "iter $iter: starting"
  # A pinned session id names the transcript the sentinel reads; its spec and
  # slice come from the hand-off, for the breach's ledger row.
  sid=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || true)
  extra=(); [[ -n $sid ]] && extra=(-- --session-id "$sid")
  cap_spec=$(sed -n 's/^SPEC=//p' "$REPO_ROOT/.ralph/handoff" 2>/dev/null | cut -c1-2); cap_spec=${cap_spec:-iter}
  cap_slice=$(sed -n 's/^SLICE=//p' "$REPO_ROOT/.ralph/handoff" 2>/dev/null); cap_slice=${cap_slice:-$iter}
  out=$("$SESSION_SH" new "$RALPH_ITER_SESSION" "$REPO_ROOT" "$MODEL" "${extra[@]}") \
    || { why=spawn; notify "ralph: could not spawn Claude session (iter $iter)"; exit $EXIT_MERIT; }
  sess=$(sed -n 's/^SESSION=//p' <<<"$out")
  url=$(sed -n 's/^URL=//p' <<<"$out")
  # The owner's link is the operator's; a worker's goes to the operator's
  # journal. A dead operator reads nothing, so then the owner gets it as before.
  if op_live; then op_event worker "iter $iter started ($MODEL): $url"
  else notify "ralph iter $iter started ($MODEL): $url"; fi

  tmux send-keys -t "$sess" "$PROMPT"
  sleep 2
  tmux capture-pane -t "$sess" -p | grep -qF 'Run one iteration per' \
    || { why=prompt-render; notify "ralph: prompt failed to render (iter $iter)"; "$SESSION_SH" kill "$sess"; exit $EXIT_MERIT; }
  tmux send-keys -t "$sess" Enter

  # Confirm the turn actually started — Enter can be swallowed by a stray
  # dialog. Busy evidence appears within seconds of a real submit; re-send
  # Enter while it hasn't.
  elapsed=0 started=""
  for _ in 1 2 3 4 5 6; do
    sleep 5
    elapsed=$((elapsed + 5))
    if pane_busy "$(tmux capture-pane -t "$sess" -p)"; then started=1; break; fi
    tmux send-keys -t "$sess" Enter
  done
  if [[ -z $started ]]; then
    # A pool that is already exhausted at submit time looks identical to a
    # swallowed Enter: the turn never goes busy. The banner is what tells
    # them apart (2026-07-24: iter 2 died here in 30s on a session limit).
    pane=$(tmux capture-pane -t "$sess" -p -S -200)
    snapshot "$iter" "prompt-never-started"
    reap_session_tools "$sess"
    "$SESSION_SH" kill "$sess" >/dev/null 2>&1 || true
    if pane_limited "$pane"; then
      why=limit
      say "iter $iter: usage limit at submit — yielding to the supervisor"
      notify_info "ralph: usage limit hit at iter $iter start — waiting for the pool to recover"
      exit $EXIT_LIMIT
    fi
    why=prompt-never-started
    notify "ralph: prompt never started a turn (iter $iter) — see .ralph/logs/iter-$iter-pane.txt"
    exit $EXIT_MERIT
  fi

  # Wait for the iteration to end. Idle is believed only after IDLE_NEED
  # consecutive idle polls, and never before FLOOR seconds — no real
  # iteration (TDD + gates + PR + CI + merge) finishes faster.
  finished="" idle_run=0 capped="" since_cap=0
  while ((elapsed < TIMEOUT)); do
    [[ -e $STOP_FILE ]] && break
    sleep "$POLL"
    elapsed=$((elapsed + POLL))
    # The token cap: exit 4 is a breach, already recorded and notified by the
    # sentinel; anything else (no transcript yet, no script) is not the driver's.
    since_cap=$((since_cap + POLL))
    if [[ -n $sid ]] && ((since_cap >= CAP_POLL)); then
      since_cap=0
      "$REPO_ROOT/scripts/token-sentinel.sh" check implement "$cap_spec" "$cap_slice" "$sid" --root "$REPO_ROOT" >/dev/null 2>"$LOG_DIR/token-cap.err"
      (($? == 4)) && { capped=1; break; }
    fi
    pane=$(tmux capture-pane -t "$sess" -p)
    if pane_busy "$pane"; then
      idle_run=0
      continue
    fi
    ((elapsed < FLOOR)) && continue
    idle_run=$((idle_run + 1))
    ((idle_run >= IDLE_NEED)) && { finished=1; break; }
  done

  if [[ -n $finished ]]; then reason=idle
  elif [[ -n $capped ]]; then reason=token-cap
  elif [[ -e $STOP_FILE ]]; then reason=stop
  else reason=ceiling; fi
  snapshot "$iter" "$reason"
  tail_text=$(tmux capture-pane -t "$sess" -p -S -200)
  reap_session_tools "$sess"
  "$SESSION_SH" kill "$sess" >/dev/null 2>&1 || true

  if [[ -n $capped ]]; then
    why=token-cap
    say "iter $iter: the session passed its token cap after ${elapsed}s — killed, loop stopped ($(head -1 "$LOG_DIR/token-cap.err" 2>/dev/null))"
    exit $EXIT_MERIT
  fi

  if grep -qF "$PROMISE" <<<"$tail_text"; then
    why=promise
    notify "ralph: completion promise '$PROMISE' reached at iter $iter — loop done"
    exit $EXIT_OK
  fi
  [[ $reason == ceiling ]] \
    && notify "ralph iter $iter hit the ${TIMEOUT}s ceiling — session killed"

  end_rev=$(main_rev)
  if [[ -n $start_rev && -n $end_rev && $end_rev != "$start_rev" ]]; then
    no_progress=0
    say "iter $iter: origin/main advanced ($start_rev -> $end_rev) after ${elapsed}s"
    op_event merged "iter $iter: origin/main $start_rev -> $end_rev after ${elapsed}s ($reason)"
  elif pane_limited "$tail_text"; then
    # Quota death, not a failure to make progress. Counting it would let two
    # unlucky outages trip the breaker and kill a healthy loop (2026-07-23).
    say "iter $iter: no merge after ${elapsed}s — usage limit, streak held at $no_progress"
    why=limit
    notify_info "ralph: usage limit hit during iter $iter — waiting for the pool to recover"
    exit $EXIT_LIMIT
  else
    no_progress=$((no_progress + 1))
    say "iter $iter: no merge landed after ${elapsed}s (no-progress streak: $no_progress)"
    op_event iter-end "iter $iter: no merge after ${elapsed}s ($reason), no-progress streak $no_progress"
    if ((no_progress >= 2)); then
      why=breaker
      notify "ralph: 2 consecutive iterations without a merge — stopping. Check PROGRESS.md for a blocker."
      exit $EXIT_MERIT
    fi
  fi
done
why=max-iters iter=$MAX_ITERS
notify "ralph: max iterations ($MAX_ITERS) reached — stopping"
exit $EXIT_OK
