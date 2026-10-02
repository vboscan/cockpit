#!/bin/sh
# cockpit.sh — start the pinned, self-updating banner (tmux with two panes).
# Shared by vicks.zsh and vicks.bash, so it is plain POSIX sh.
#
#   cockpit.sh           banner on top, shell below
#   cockpit.sh side      banner in a right-hand column
#   cockpit.sh refresh   look everything up again right now
#   cockpit.sh speedtest run the speed tests again right now
#   cockpit.sh review    ask Claude to check the dashboard now and list what needs attention
#   cockpit.sh fix [n]   open Claude on those findings, or on finding number n

VICKS_HOME=${VICKS_HOME:-$(cd "$(dirname "$0")" && pwd)}
layout=${1:-${VICKS_COCKPIT_LAYOUT:-top}}

if [ "$layout" = review ]; then
  # ask Claude to check the dashboard again right now and print what it finds
  exec zsh "$VICKS_HOME/banner.zsh" --review
fi
if [ "$layout" = fix ]; then
  # open an interactive Claude session that starts from the findings (optionally one of them)
  shift
  exec zsh "$VICKS_HOME/banner.zsh" --fix "$@"
fi
if [ "$layout" = speedtest ]; then
  # run the internet and Tailscale speed tests again right now
  exec zsh "$VICKS_HOME/banner.zsh" --speedtest
fi
if [ "$layout" = refresh ]; then
  # refill the shared cache; every open dashboard shows it on its next redraw
  zsh "$VICKS_HOME/banner.zsh" --fresh >/dev/null 2>&1
  echo "Refreshed. Update checks continue in the background."
  exit 0
fi

command -v tmux >/dev/null 2>&1 || { echo "cockpit needs tmux. Run $VICKS_HOME/install.sh to install it."; exit 1; }
command -v zsh  >/dev/null 2>&1 || { echo "cockpit needs zsh. Run $VICKS_HOME/install.sh to install it."; exit 1; }
if [ -n "${TMUX:-}" ]; then
  echo "Already inside the cockpit (or another tmux). Try: cockpit refresh"; exit 1
fi

# --new-window: the dashboard starts the once-per-window speed tests
dash="zsh '$VICKS_HOME/banner.zsh' --dash --new-window"
t() { tmux -L vicks -f "$VICKS_HOME/tmux.conf" "$@"; }

# Shells inside the cockpit must not print their own banner or start a second cockpit.
# tmux.conf sets these for a new server; this covers a server that is already running.
t source-file "$VICKS_HOME/tmux.conf" 2>/dev/null   # refresh a server that is already running
t set-environment -g VICKS_NO_BANNER 1 2>/dev/null
t set-environment -g VICKS_IN_COCKPIT 1 2>/dev/null

# destroy-unattached: closing the terminal (or the SSH connection) ends the session
# and its dashboard. @vicks_dash marks the banner pane so tmux.conf keeps focus out of it.
if [ "$layout" = side ]; then
  t new-session \; set-option destroy-unattached on \; \
    split-window -h -d -l 66 "$dash --side" \; set-option -p -t '{right}' @vicks_dash 1
else
  t new-session \; set-option destroy-unattached on \; \
    split-window -v -b -d -l 12 "$dash" \; set-option -p -t '{top}' @vicks_dash 1
fi
