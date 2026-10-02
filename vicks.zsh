# vicks.zsh — entry point, sourced from ~/.zshrc (install.sh adds the line).
# Sets up the prompt. Every new terminal then opens in the cockpit: the banner
# stays pinned at the top and updates itself while commands scroll underneath.
#
# Commands:  hello [--fresh|--no-net]   print the full banner once
#            cockpit [top|side]         start the cockpit by hand
#            cockpit refresh            look everything up again right now
#
# Settings (export them in ~/.zshrc above the vicks block):
#   VICKS_AUTO_COCKPIT=0   new terminals show the one-off banner instead of the cockpit
#   VICKS_COCKPIT_LAYOUT=side   pinned banner in a right-hand column instead of on top
#   VICKS_NO_BANNER=1      no banner at all on new shells
#   VICKS_NO_NET=1         banner without public IP / traceroute

[[ -o interactive ]] || return 0

export VICKS_HOME=${${(%):-%x}:A:h}
export VIRTUAL_ENV_DISABLE_PROMPT=1   # the prompt shows the venv itself

# `hello` prints the banner any time; `hello --fresh` bypasses the network cache.
hello() { zsh "$VICKS_HOME/banner.zsh" "$@"; }

# `cockpit` opens tmux with the live dashboard in one pane and a shell in the other.
# Commands scroll in the shell pane; the dashboard stays put and refreshes itself.
cockpit() {
  local layout=${1:-${VICKS_COCKPIT_LAYOUT:-top}}
  if [[ $layout == refresh ]]; then
    # refill the shared cache; every open dashboard shows it on its next redraw
    zsh "$VICKS_HOME/banner.zsh" --fresh >/dev/null 2>&1
    print "Refreshed. Update checks for macOS and Homebrew continue in the background."
    return 0
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    print "cockpit needs tmux. Install it with: brew install tmux"; return 1
  fi
  if [[ -n ${TMUX:-} ]]; then
    print "Already inside the cockpit (or another tmux). Try: cockpit refresh"; return 1
  fi
  local dash="zsh ${(q)VICKS_HOME}/banner.zsh --dash"
  local -a split
  local where
  if [[ $layout == side ]]; then
    split=(split-window -h -d -l 66 "$dash --side"); where='{right}'   # dashboard on the right
  else
    split=(split-window -v -b -d -l 12 "$dash"); where='{top}'         # on top, sizes itself
  fi
  # destroy-unattached: closing the terminal window ends the session and its dashboard.
  # @vicks_dash marks the dashboard pane so tmux.conf can keep focus out of it.
  tmux -L vicks -f "$VICKS_HOME/tmux.conf" new-session \
    -e VICKS_NO_BANNER=1 -e VICKS_IN_COCKPIT=1 \; \
    set-option destroy-unattached on \; \
    "${split[@]}" \; \
    set-option -p -t "$where" @vicks_dash 1
}

# ── prompt ───────────────────────────────────────────────────────────────
if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="$VICKS_HOME/starship.toml"
  eval "$(starship init zsh)"
else
  source "$VICKS_HOME/prompt-fallback.zsh"
fi

# ── cockpit or banner ────────────────────────────────────────────────────
# The cockpit starts by itself only in a real, roomy terminal window: not inside
# tmux, not for `zsh -c`, not in IDE terminal panels, and not when switched off.
_vicks_wants_cockpit() {
  [[ ${VICKS_AUTO_COCKPIT:-1} != 0 ]] || return 1
  [[ -t 0 && -t 1 ]] || return 1
  [[ -z ${TMUX:-} && -z ${VICKS_IN_COCKPIT:-} && -z ${ZSH_EXECUTION_STRING:-} ]] || return 1
  [[ ${TERM_PROGRAM:-} != vscode && -z ${INSIDE_EMACS:-} && ${TERMINAL_EMULATOR:-} != JetBrains* ]] || return 1
  (( ${LINES:-0} >= 30 && ${COLUMNS:-0} >= 80 )) || return 1
  command -v tmux >/dev/null 2>&1
}

if _vicks_wants_cockpit; then
  typeset -i _vicks_t0=$SECONDS
  if cockpit && (( SECONDS - _vicks_t0 >= 3 )); then
    exit        # the terminal *was* the cockpit: leaving it closes the terminal
  fi
  # tmux failed or ended at once: never lock the user out, fall back to a plain shell
  print -P "%F{214}The cockpit did not start. This is a normal shell. Set VICKS_AUTO_COCKPIT=0 in ~/.zshrc to stop trying.%f"
  unset _vicks_t0
elif [[ -z ${VICKS_NO_BANNER:-} && -t 1 ]]; then
  hello ${VICKS_NO_NET:+--no-net}
fi
