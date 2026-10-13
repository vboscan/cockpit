#!/usr/bin/env bash
# claude-session.sh — manage detached tmux sessions running Claude Code.
# Used by .claude/skills/new-session (see its SKILL.md for the agent-facing flow).
#
#   claude-session.sh new [name] [dir] [model] [-- <claude args>…]
#                                           create session (default name claude-agent,
#                                           auto-suffix -2, -3, … if taken), launch
#                                           claude in auto mode (optionally pinned to
#                                           <model>, e.g. claude-opus-5-5), enable
#                                           /remote-control. Prints SESSION= and URL=.
#                                           Arguments after -- are added to the claude
#                                           command line, each shell-quoted (the
#                                           operator's deny rules, ralph-operator.sh).
#   claude-session.sh kill <name>           quit Claude gracefully, kill the session.
#   claude-session.sh kill-all [--include-self]
#                                           kill every claude-agent* session; the one
#                                           hosting this shell is kept unless
#                                           --include-self, in which case it dies LAST.
set -uo pipefail

PREFIX=claude-agent

self_session() { tmux display-message -p '#S' 2>/dev/null || true; }

# --- remote-control pane predicates ------------------------------------------
# Pulled out of cmd_new so they can be tested against real captured panes
# (scripts/test-remote-control.sh) — the same reason pane_limited moved into
# pane-busy.sh. A private copy inside cmd_new is precisely how the 2026-09-01
# breakage went unnoticed until the Ralph loop could not start an iteration.
#
# The client's remote-control UI has now taken three shapes, so each of these
# accepts ALL of them rather than the newest: an older client on the box must
# keep working, and the failure mode of being too strict is a loop that stops
# dead on a merit exit (ralph-driver.sh treats a spawn failure as a human
# problem and does not relaunch).

# rc_active <pane> — has remote control come up, in any of its forms?
#   v2.1.25x  a confirmation dialog naming the session
#   older     a `/remote-control is active` transcript line
#   either    the `/rc` badge, once the dialog has been dismissed
rc_active() {
  grep -q 'This session is available' <<<"$1" && return 0
  grep -q 'remote-control is active' <<<"$1" && return 0
  grep -qE '(^|[^[:alnum:]])/rc([^[:alnum:]]|$)' <<<"$1"
}

# rc_dialog_open <pane> — is the confirmation dialog waiting for a keypress?
# Deliberately NOT matched by the "Select remote environment" picker: that one
# is answered with Enter, and an Esc would cancel it.
rc_dialog_open() { grep -q 'This session is available' <<<"$1"; }

# trust_dialog_open <pane> — Claude Code's first-run "do you trust this folder?"
# prompt, shown the first time it opens a directory it has not seen before.
#
# This blocks EVERY new project, which is exactly when a kit install is being
# stood up. It is nastier than it looks: the dialog's menu cursor is also `❯`,
# so the readiness poll below (which waits for the `❯` input prompt) matches the
# DIALOG and reports the session ready. cmd_new then types /remote-control into
# a menu that cannot accept text and fails with a misleading
# "/remote-control not on input line" — which ralph-driver.sh treats as a spawn
# failure and a merit stop, so the loop never starts and the reason is wrong.
#
# Matched on the option text rather than the question, because the question
# wording is prose and the option is what we must select.
trust_dialog_open() { grep -q 'Yes, I trust this folder' <<<"$1"; }

# input_prompt_ready <pane> — the real `❯` input line, not a menu cursor.
# Any open dialog disqualifies it: both draw `❯`, and only one takes text.
input_prompt_ready() {
  trust_dialog_open "$1" && return 1
  grep -q '❯' <<<"$1"
}

# rc_url <pane> — the session URL, which is only on screen while the dialog is
# up. Read it BEFORE dismissing; Esc redraws the pane and takes it away.
rc_url() { grep -o 'https://claude.ai/code/session_[A-Za-z0-9]*' <<<"$1" | tail -1; }

# rc_url_ready <pane> — is a URL actually on screen to be read?
#
# This is what cmd_new must wait for, and it is NOT the same question as either
# rc_active or rc_dialog_open. Two ways to get that wrong, both observed on
# 2026-09-01:
#   - rc_active is true from the first poll (remote control is already on at
#     launch under v2.1.25x, so the `/rc` badge is always there), which exits
#     the wait before the dialog has even drawn;
#   - the dialog itself appears BEFORE the session registers with the backend,
#     and in that state it reads "…mobile app and claude.ai/code." with no
#     session URL at all.
# Both produce `FAIL: no remote-control URL found`. So the only honest test is
# whether a URL is literally on the pane.
rc_url_ready() { [[ -n $(rc_url "$1") ]]; }

# poll_pane <session> <pattern> [tries×0.5s] — wait until the pane shows <pattern>
poll_pane() {
  local s=$1 pat=$2 tries=${3:-40} i
  for ((i = 0; i < tries; i++)); do
    if tmux capture-pane -t "$s" -p | grep -q "$pat"; then return 0; fi
    sleep 0.5
  done
  return 1
}

cmd_new() {
  local pos=() a
  while (($#)) && [[ $1 != -- ]]; do pos+=("$1"); shift; done
  (($#)) && shift # the --; what is left goes to claude
  local base=${pos[0]:-$PREFIX} dir=${pos[1]:-} model=${pos[2]:-} s i=1 cmd='claude --permission-mode auto'
  [[ -n $model ]] && cmd+=" --model $model"
  # Typed into the pane's shell, so every extra argument is quoted for it: a
  # deny rule is `Edit(//path/**)`, which an unquoted shell would glob.
  for a in "$@"; do cmd+=" $(printf '%q' "$a")"; done
  s=$base
  # =name: exact. A bare target also matches a session the name only prefixes
  # (ralph-x for ralph-x-operator), so every has-session, send-keys and
  # kill-session here names its session exactly (found live, 2026-10-11).
  while tmux has-session -t "=$s" 2>/dev/null; do i=$((i + 1)); s="$base-$i"; done

  tmux new-session -d -s "$s" -x 220 -y 50 ${dir:+-c "$dir"}
  # 'window-size latest' lets a detached window collapse to ~80 cols (observed
  # 78x35), truncating the status-bar hints the ralph driver greps for its
  # busy check ("esc to interrupt" → "esc to i…") — pin the size instead.
  tmux set-option -w -t "$s" window-size manual
  tmux resize-window -t "$s" -x 220 -y 50
  tmux send-keys -t "$s" "$cmd" Enter

  # Clear the first-run trust dialog before waiting for readiness. Accepting is
  # consistent with intent — the caller named this directory and is launching an
  # agent in it — but it is a real trust decision, so it is explicit and can be
  # turned off with RALPH_SESSION_AUTO_TRUST=0, in which case a human answers.
  for _ in $(seq 1 30); do
    p=$(tmux capture-pane -t "$s" -p 2>/dev/null)
    trust_dialog_open "$p" || { grep -q '❯' <<<"$p" && break; sleep 1; continue; }
    if [[ ${RALPH_SESSION_AUTO_TRUST:-1} == 0 ]]; then
      echo "FAIL: $s is waiting on the trust-folder dialog and RALPH_SESSION_AUTO_TRUST=0" >&2
      return 1
    fi
    # "Yes, I trust this folder" sits directly below the default "No, exit".
    tmux send-keys -t "$s" Down; sleep 0.5; tmux send-keys -t "$s" Enter
    sleep 2
    break
  done

  # readiness = the ❯ input prompt; status-bar text varies (e.g. "? for shortcuts"
  # vs "install gh for PR status") so it is not a reliable signal. Uses
  # input_prompt_ready, not a bare `❯`, so a dialog's menu cursor cannot be
  # mistaken for a prompt that accepts text.
  for _ in $(seq 1 30); do
    input_prompt_ready "$(tmux capture-pane -t "$s" -p 2>/dev/null)" && break
    tmux has-session -t "=$s" 2>/dev/null || { echo "FAIL: $s died before the prompt appeared (trust dialog answered 'No, exit'?)" >&2; return 1; }
    sleep 1
  done
  input_prompt_ready "$(tmux capture-pane -t "$s" -p 2>/dev/null)" \
    || { echo "FAIL: claude prompt never appeared in $s" >&2; return 1; }

  # Send the FULL command, then wait for it to render on the input line before Enter —
  # a partial match + Enter can select the wrong autocomplete item (e.g. /remote-env).
  # NB: the char after ❯ is a non-breaking space (U+00A0), so match with .* not ' '.
  tmux send-keys -t "$s" '/remote-control'
  poll_pane "$s" '❯.*/remote-control' 20 || { echo "FAIL: /remote-control not on input line in $s" >&2; return 1; }
  tmux send-keys -t "$s" Enter

  # Wait for activation; accept the default if an environment picker appears.
  # Capture the URL here rather than after the loop: the v2.1.25x dialog is the
  # only place it appears, and dismissing the dialog wipes it from the pane.
  # Wait for a pane that CARRIES the URL, not merely for one that says remote
  # control is on — see rc_url_ready. A dialog that appears before the session
  # has registered names no URL, so it is dismissed and re-opened until it does.
  local ok="" p url=""
  for ((i = 0; i < 60; i++)); do
    p=$(tmux capture-pane -t "$s" -p -S -100)
    if rc_url_ready "$p"; then
      url=$(rc_url "$p")
      # The dialog blocks the input line; dismiss it before anything else is
      # typed. The legacy transcript line needs no dismissal.
      rc_dialog_open "$p" && { tmux send-keys -t "$s" Escape; sleep 0.5; }
      ok=1
      break
    fi
    if rc_dialog_open "$p"; then
      # Up, but registration has not landed. Dismiss and ask again — the panel
      # is redrawn from scratch each time and gains the URL once it exists.
      tmux send-keys -t "$s" Escape
      sleep 2
      tmux send-keys -t "$s" '/remote-control'
      poll_pane "$s" '❯.*/remote-control' 20 && tmux send-keys -t "$s" Enter
      sleep 1
      continue
    fi
    grep -q 'Select remote environment' <<<"$p" && tmux send-keys -t "$s" Enter
    sleep 0.5
  done
  [[ -n $ok ]] || { echo "FAIL: remote control never activated in $s" >&2; return 1; }

  # --permission-mode auto should already have it on; cycle as a fallback.
  for ((i = 0; i < 6; i++)); do
    tmux capture-pane -t "$s" -p | grep -q 'auto mode on' && break
    tmux send-keys -t "$s" BTab
    sleep 0.5
  done
  tmux capture-pane -t "$s" -p | grep -q 'auto mode on' \
    || { echo "FAIL: could not enable auto mode in $s" >&2; return 1; }

  # Normally already captured above, while the dialog was still on screen.
  [[ -n $url ]] || url=$(rc_url "$(tmux capture-pane -t "$s" -p -S -100)")
  [[ -n $url ]] || { echo "FAIL: no remote-control URL found in $s" >&2; return 1; }
  echo "SESSION=$s"
  echo "URL=$url"
}

# quit Claude with a double Ctrl-C, then kill the tmux session
kill_one() {
  local s=$1
  # "=$s:" — the exact session, as a window target: send-keys takes a pane, and
  # tmux 3.4 rejects a bare "=name" there ("can't find pane"), probed 2026-10-11
  tmux send-keys -t "=$s:" C-c
  sleep 0.3
  tmux send-keys -t "=$s:" C-c
  sleep 1
  tmux kill-session -t "=$s" 2>/dev/null
  if tmux has-session -t "=$s" 2>/dev/null; then echo "FAIL: $s still alive" >&2; return 1; fi
  echo "KILLED $s"
}

cmd_kill() {
  local s=${1:?usage: claude-session.sh kill <name>}
  tmux has-session -t "=$s" 2>/dev/null || { echo "FAIL: no session named $s" >&2; return 1; }
  [[ $s == "$(self_session)" ]] && { echo "REFUSED: $s hosts this shell — use kill-all --include-self if you really mean it" >&2; return 1; }
  kill_one "$s"
}

cmd_kill_all() {
  local include_self=${1:-} self rc=0 s
  self=$(self_session)
  while IFS= read -r s; do
    [[ -z $s ]] && continue
    if [[ $s == "$self" ]]; then
      if [[ $include_self == --include-self ]]; then continue; fi # killed last, below
      echo "KEPT $s (current)"
      continue
    fi
    kill_one "$s" || rc=1
  done < <(tmux list-sessions -F '#S' 2>/dev/null | grep "^$PREFIX" || true)
  if [[ $include_self == --include-self && -n $self ]] && tmux has-session -t "=$self" 2>/dev/null; then
    kill_one "$self" || rc=1 # ends this shell's session — everything above already ran
  fi
  return "$rc"
}

# Sourced by scripts/test-remote-control.sh for the predicates above; skip the
# dispatch so sourcing does not print usage and exit 2.
[[ -n ${CLAUDE_SESSION_LIB_ONLY:-} ]] && return 0

case ${1:-} in
  new) shift; cmd_new "$@" ;;
  kill) shift; cmd_kill "$@" ;;
  kill-all) shift; cmd_kill_all "$@" ;;
  # The header block, however long it is — a fixed line range prints shell code
  # the first time the comment above it gains a line, which is what `2,16p` had
  # already started doing (line 16 is `set -uo pipefail`).
  *) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 2 ;;
esac
