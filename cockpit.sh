#!/bin/sh
# cockpit.sh — run a terminal inside tmux and keep one pinned banner per workspace.
# Shared by vicks.zsh and vicks.bash, so it is plain POSIX sh.
#
# Every terminal gets its own tmux session holding just its shell. The banner is one
# extra pane, and exactly one session per cmux workspace has it. Because the banner is
# only a pane, it can be added to (or taken from) a running terminal without touching
# the shell in it. Outside cmux there are no workspaces, so every terminal has a banner.
#
#   cockpit.sh            start this terminal's session (what a new terminal runs)
#   cockpit.sh side       the same, with the banner as a right-hand column
#   cockpit.sh here       move this workspace's banner into the terminal you are in
#   cockpit.sh reconcile  make sure each workspace has exactly one banner (runs by itself)
#   cockpit.sh refresh    look everything up again right now
#   cockpit.sh speedtest  run the speed tests again right now
#   cockpit.sh review     ask Claude to check the dashboard now and list what needs attention
#   cockpit.sh fix [n]    open Claude on those findings, or on finding number n
#
# Settings: VICKS_COCKPIT_LAYOUT=side, VICKS_TMUX_SOCKET=vicks (tmux server name)

VICKS_HOME=${VICKS_HOME:-$(cd "$(dirname "$0")" && pwd)}
action=${1:-${VICKS_COCKPIT_LAYOUT:-top}}

case $action in
  review)    exec zsh "$VICKS_HOME/banner.zsh" --review ;;
  fix)       shift; exec zsh "$VICKS_HOME/banner.zsh" --fix "$@" ;;
  speedtest) exec zsh "$VICKS_HOME/banner.zsh" --speedtest ;;
  refresh)
    # refill the shared cache; every open dashboard shows it on its next redraw
    zsh "$VICKS_HOME/banner.zsh" --fresh >/dev/null 2>&1
    echo "Refreshed. Update checks continue in the background."
    exit 0 ;;
esac

command -v tmux >/dev/null 2>&1 || { echo "cockpit needs tmux. Run $VICKS_HOME/install.sh to install it."; exit 1; }
command -v zsh  >/dev/null 2>&1 || { echo "cockpit needs zsh. Run $VICKS_HOME/install.sh to install it."; exit 1; }

sock=${VICKS_TMUX_SOCKET:-vicks}
t() { tmux -L "$sock" -f "$VICKS_HOME/tmux.conf" "$@"; }   # our own tmux server, by name

MIN_COLS=80 MIN_ROWS=30      # a window smaller than this is never given the banner

# add_banner <session-name>: put the banner pane into that session, across the whole
# window (-f), without taking focus (-d). @vicks_dash marks it for tmux.conf and for us.
add_banner() {
  lay=$(t show-options -qv -t "=$1:" @vicks_layout 2>/dev/null)
  if [ "$lay" = side ]; then
    new=$(t split-window -f -h -d -l 66 -t "=$1:" -P -F '#{pane_id}' "zsh '$VICKS_HOME/banner.zsh' --dash --side") || return 1
  else
    new=$(t split-window -f -v -b -d -l 12 -t "=$1:" -P -F '#{pane_id}' "zsh '$VICKS_HOME/banner.zsh' --dash") || return 1
  fi
  t set-option -p -t "$new" @vicks_dash 1
}

# banners_of <workspace>: its banner panes, the one in the most recently used session first
banners_of() {
  t list-panes -a -F '#{session_activity} #{pane_id} #{@vicks_dash} #{@vicks_ws}' 2>/dev/null \
    | awk -v w="$1" '$3 == 1 && $4 == w {print $1, $2}' | sort -rn | awk '{print $2}'
}

# reconcile: for every workspace with live sessions, make the number of banners exactly one.
reconcile() {
  # one reconcile at a time: several terminals can start in the same instant
  lock="${TMPDIR:-/tmp}/vicks-reconcile-$(id -u).lock"; tries=0
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1)); [ "$tries" -gt 60 ] && rmdir "$lock" 2>/dev/null   # stale after 6s
    sleep 0.1
  done
  trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM

  t list-sessions -F '#{@vicks_ws}' 2>/dev/null | sort -u | while IFS= read -r ws; do
    [ -n "$ws" ] || continue
    set -- $(banners_of "$ws")
    if [ $# -eq 0 ]; then
      # none: give it to the most recently used session that is big enough
      target=$(t list-sessions -F '#{session_activity} #{window_width} #{window_height} #{session_name} #{@vicks_ws}' \
        | awk -v w="$ws" -v c=$MIN_COLS -v r=$MIN_ROWS '$5 == w && $2 >= c && $3 >= r {print $1, $4}' \
        | sort -rn | head -1 | cut -d' ' -f2)
      [ -n "$target" ] && add_banner "$target"
    else
      # more than one: keep the first (most recently used), close the others
      shift
      for p in "$@"; do t kill-pane -t "$p" 2>/dev/null; done
    fi
  done
}

# sweep_pills: remove sidebar SSH pills whose tmux pane no longer exists, which happens
# when a terminal is closed while its ssh session is still open. Pill keys are
# "ssh-<pane number>" (see the ssh wrapper in vicks.zsh).
sweep_pills() {
  command -v cmux >/dev/null 2>&1 || return 0
  panes=" $(t list-panes -a -F '#{pane_id}' 2>/dev/null | tr -d '%' | tr '\n' ' ')"
  t list-sessions -F '#{@vicks_ws}' 2>/dev/null | sort -u | while IFS= read -r ws; do
    case $ws in ''|solo-*) continue ;; esac
    CMUX_QUIET=1 cmux list-status --workspace "$ws" 2>/dev/null \
      | sed -n 's/^\(ssh-[0-9][0-9]*\)=.*/\1/p' | while IFS= read -r key; do
        case $panes in
          *" ${key#ssh-} "*) ;;
          *) CMUX_QUIET=1 cmux clear-status "$key" --workspace "$ws" >/dev/null 2>&1 ;;
        esac
      done
  done
}

case $action in
  reconcile) reconcile; sweep_pills; exit 0 ;;
  here)
    [ -n "${TMUX:-}" ] && [ -n "${VICKS_IN_COCKPIT:-}" ] || { echo "This is not a pinned terminal, so there is no banner to move here."; exit 1; }
    ws=$(t display-message -p '#{@vicks_ws}'); me=$(t display-message -p '#{session_name}')
    [ -n "$ws" ] || { echo "This terminal was opened before workspaces were tracked. Open a new one."; exit 1; }
    for p in $(banners_of "$ws"); do t kill-pane -t "$p" 2>/dev/null; done
    add_banner "$me" && exit 0
    echo "Could not add the banner here."; exit 1 ;;
esac

# ── start this terminal's session ────────────────────────────────────────
if [ -n "${TMUX:-}" ]; then
  echo "This terminal is already inside tmux. Try: cockpit here, cockpit refresh"; exit 1
fi
layout=top; [ "$action" = side ] && layout=side

# A server that is already running picks up config changes, and its shells must know
# they are inside the cockpit (tmux.conf does both for a new server).
t source-file "$VICKS_HOME/tmux.conf" 2>/dev/null
t set-environment -g VICKS_NO_BANNER 1 2>/dev/null
t set-environment -g VICKS_IN_COCKPIT 1 2>/dev/null

# The once-per-window background jobs (speed tests) belong to the terminal opening,
# not to the banner, which may live in another terminal.
zsh "$VICKS_HOME/banner.zsh" --kick >/dev/null 2>&1 &

# @vicks_ws names the group that shares one banner: the cmux workspace, or, outside
# cmux, a value unique to this session so that every terminal has its own.
# destroy-unattached: closing the terminal ends the session. When a session ends, the
# session-closed hook reconciles, so a workspace that lost its banner gets it back in
# another terminal.
rec="VICKS_TMUX_SOCKET='$sock' sh '$VICKS_HOME/cockpit.sh' reconcile"
if [ -n "${CMUX_WORKSPACE_ID:-}" ]; then
  t new-session \; set-option destroy-unattached on \; set-option @vicks_layout "$layout" \; \
    set-option @vicks_ws "$CMUX_WORKSPACE_ID" \; \
    set-hook -g session-closed "run-shell -b \"$rec\"" \; run-shell -b "$rec"
else
  t new-session \; set-option destroy-unattached on \; set-option @vicks_layout "$layout" \; \
    set-option -F @vicks_ws 'solo-#{session_id}' \; \
    set-hook -g session-closed "run-shell -b \"$rec\"" \; run-shell -b "$rec"
fi
