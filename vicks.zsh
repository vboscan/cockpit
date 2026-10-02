# vicks.zsh — entry point, sourced from ~/.zshrc (install.sh adds the line).
# Sets up the prompt and shows the welcome banner on every new interactive shell.
#
# Commands:  hello [--fresh|--no-net]   show the banner again
#            cockpit [top|side]         live dashboard pinned above (or beside) the shell
#
# Settings (export them in ~/.zshrc above the vicks block):
#   VICKS_NO_BANNER=1      no banner on new shells
#   VICKS_NO_NET=1         banner without public IP / traceroute
#   VICKS_AUTO_COCKPIT=1   every new terminal opens straight into the cockpit
#   VICKS_COCKPIT_LAYOUT=side   default cockpit layout (top or side)

[[ -o interactive ]] || return 0

export VICKS_HOME=${${(%):-%x}:A:h}
export VIRTUAL_ENV_DISABLE_PROMPT=1   # the prompt shows the venv itself

# `hello` re-runs the banner any time; `hello --fresh` bypasses the network cache.
hello() { zsh "$VICKS_HOME/banner.zsh" "$@"; }

# `cockpit` opens tmux with the live dashboard in one pane and a shell in the other.
# Commands scroll in the shell pane; the dashboard stays put and refreshes itself.
cockpit() {
  if ! command -v tmux >/dev/null 2>&1; then
    print "cockpit needs tmux. Install it with: brew install tmux"; return 1
  fi
  if [[ -n ${TMUX:-} ]]; then
    print "Already inside tmux. Run 'hello' for a one-off banner."; return 1
  fi
  local layout=${1:-${VICKS_COCKPIT_LAYOUT:-top}}
  local dash="zsh ${(q)VICKS_HOME}/banner.zsh --dash"
  local -a split
  if [[ $layout == side ]]; then
    split=(split-window -h -d -l 66 "$dash --side")       # dashboard on the right
  else
    split=(split-window -v -b -d -l 12 "$dash")           # dashboard on top, sizes itself
  fi
  tmux -L vicks -f "$VICKS_HOME/tmux.conf" new-session \
    -e VICKS_NO_BANNER=1 -e VICKS_IN_COCKPIT=1 \; "${split[@]}"
}

# ── prompt ───────────────────────────────────────────────────────────────
if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="$VICKS_HOME/starship.toml"
  eval "$(starship init zsh)"
else
  source "$VICKS_HOME/prompt-fallback.zsh"
fi

# ── banner or cockpit ────────────────────────────────────────────────────
if [[ -t 1 && -z ${TMUX:-} && -n ${VICKS_AUTO_COCKPIT:-} && ${TERM_PROGRAM:-} != vscode ]] \
   && command -v tmux >/dev/null 2>&1; then
  # the terminal *is* the cockpit: leaving it closes the terminal
  cockpit && exit
elif [[ -z ${VICKS_NO_BANNER:-} && -t 1 ]]; then
  hello ${VICKS_NO_NET:+--no-net}
fi
