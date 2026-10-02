#!/bin/sh
# btw-side.sh — open a Claude Code /btw side question as a new interactive session in
# a pane to the right of the session that asked. The new session is a fork of the
# asking one, so it knows the conversation so far and has its own history.
#
# In the cockpit (or any tmux) the pane is a tmux split of this window, so the banner
# stays shared. Outside tmux, inside cmux, it is a cmux split.
#
#   btw-side.sh hook                 UserPromptExpansion hook (hook JSON on stdin):
#                                    handles /btw and blocks it, so the main session
#                                    spends no turn on it
#   btw-side.sh open <session-id>    the same by hand; the question comes on stdin
#   btw-side.sh run <job-dir>        what the new pane runs
#
# Settings:
#   BTW_FOCUS=true   move keyboard focus to the new pane (default: stay where you are)

self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

# open_side <session-id> <cwd> <question>: returns 1 when there is nowhere to open a pane.
open_side() {
  [ -n "${TMUX:-}${CMUX_WORKSPACE_ID:-}" ] || return 1

  job=$(mktemp -d "${TMPDIR:-/tmp}/claude-btw.XXXXXX") || return 1
  printf '%s' "$1" > "$job/session"
  printf '%s' "$2" > "$job/cwd"
  printf '%s' "$3" > "$job/question"
  run="sh '$self' run '$job'"

  if [ -n "${TMUX:-}" ]; then
    detached=-d; [ "${BTW_FOCUS:-false}" = true ] && detached=
    tmux split-window -h $detached ${TMUX_PANE:+-t "$TMUX_PANE"} "$run" 2>/dev/null
  else
    cmux new-split right --workspace "$CMUX_WORKSPACE_ID" \
      ${CMUX_SURFACE_ID:+--surface "$CMUX_SURFACE_ID"} \
      --focus "${BTW_FOCUS:-false}" --command "$run" >/dev/null 2>&1
  fi || { rm -rf "$job"; return 1; }
}

case ${1:-} in
  hook)
    input=$(cat)
    [ "$(printf '%s' "$input" | jq -r '.command_name // empty')" = btw ] || exit 0
    # Nowhere to open a pane: say nothing, so the skill text goes to Claude and it answers inline.
    open_side "$(printf '%s' "$input" | jq -r '.session_id')" \
              "$(printf '%s' "$input" | jq -r '.cwd')" \
              "$(printf '%s' "$input" | jq -r '.command_args // empty')" || exit 0
    jq -n '{decision: "block", reason: "Side question opened in a new session on the right."}'
    ;;
  open)
    [ -n "${2:-}" ] || { echo "usage: btw-side.sh open <session-id>  (question on stdin)" >&2; exit 2; }
    open_side "$2" "$PWD" "$(cat)" || { echo "Not inside tmux or cmux: no side pane to open." >&2; exit 1; }
    echo "Side question opened in a new session on the right."
    ;;
  run)
    job=${2:?job dir}
    sid=$(cat "$job/session") cwd=$(cat "$job/cwd") question=$(cat "$job/question")
    rm -rf "$job"
    cd "$cwd" || exit 1
    if [ -n "$question" ]; then
      claude --resume "$sid" --fork-session -n "btw: $(printf '%s' "$question" | tr '\n' ' ' | cut -c1-40)" "$question"
    else
      claude --resume "$sid" --fork-session -n "btw"
    fi && exit 0
    # a tmux pane closes with its command: keep the error on screen until a key is pressed
    printf '\nThe side session did not start. Press Enter to close. '; read -r _
    ;;
  *)
    echo "usage: btw-side.sh hook | open <session-id> | run <job-dir>" >&2; exit 2
    ;;
esac
