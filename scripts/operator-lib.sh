#!/usr/bin/env bash
# ANCHOR: operator-lib — the run journal the standing operator reads
# (scripts/ralph-operator.sh, ralph/OPERATOR.md). Sourced, never run.
#
# The driver, the heartbeat and notify.sh append what happened to one file,
# .ralph/operator/events, so `ralph-operator.sh wait` can block on it and hand
# the operator a report instead of a pane to read. One line per event:
#   <iso-ts> TAB <kind> TAB <text>
#
# A run has an operator only while .ralph/operator/run exists (written by
# `ralph-operator.sh start`). Without it every function here is a no-op, so a
# loop with no operator behaves exactly as it did before the operator existed.
# Requires RALPH_REPO_ROOT and RALPH_OPERATOR_SESSION (scripts/ralph-config.sh).

OP_DIR="$RALPH_REPO_ROOT/.ralph/operator"
OP_RUN="$OP_DIR/run"
OP_EVENTS="$OP_DIR/events"

# op_active — this run has an operator (it may since have died; see op_live).
op_active() { [[ -f $OP_RUN ]]; }

# op_session — the run's current operator session. There is one per incident
# (ralph-operator.sh note, handoff), each appending its SESSION= to the run file.
op_session() {
  local s
  s=$(sed -n 's/^SESSION=//p' "$OP_RUN" 2>/dev/null | tail -1)
  echo "${s:-$RALPH_OPERATOR_SESSION}"
}

# op_live — this run has an operator AND its session is up. Worker links go to
# the operator only then: a dead operator reads nothing, so the owner gets them.
# =name: exact; a bare name also matches a session it only prefixes.
op_live() { op_active && tmux has-session -t "=$(op_session)" 2>/dev/null; }

# op_event <kind> <text> — append one event. Never fails its caller.
op_event() {
  op_active || return 0
  local text=${2-}
  text=${text//$'\t'/ }; text=${text//$'\n'/ ⏎ }
  printf '%s\t%s\t%s\n' "$(date -Is)" "$1" "$text" >>"$OP_EVENTS" 2>/dev/null || true
}
