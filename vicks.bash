# vicks.bash — entry point for bash, sourced from ~/.bashrc (install.sh adds the line).
# The bash twin of vicks.zsh, for machines whose login shell is bash (most Linux
# servers). The banner itself is a zsh script, so zsh must be installed, but your
# shell stays bash. Written for bash 3.2 and newer.
#
# Commands and settings are the same as in vicks.zsh:
#   hello, cockpit, cockpit refresh
#   VICKS_AUTO_COCKPIT=0, VICKS_COCKPIT_LAYOUT=side, VICKS_REMOTE_ART=deathstar,
#   VICKS_NO_BANNER=1, VICKS_NO_NET=1   (export them in ~/.bashrc above the vicks block)

case $- in *i*) ;; *) return 0 ;; esac

VICKS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export VICKS_HOME
export VIRTUAL_ENV_DISABLE_PROMPT=1   # the prompt shows the venv itself
# Who logged in to this terminal: the owner of the terminal device. That stays the
# same through sudo, su and tmux, so the prompt can flag commands run as someone else.
_vicks_tty=$(tty 2>/dev/null)
export VICKS_LOGIN_USER="${VICKS_LOGIN_USER:-$(stat -c %U "$_vicks_tty" 2>/dev/null || stat -f %Su "$_vicks_tty" 2>/dev/null)}"
unset _vicks_tty
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" ;; esac

hello()   { zsh "$VICKS_HOME/banner.zsh" "$@"; }
cockpit() { sh "$VICKS_HOME/cockpit.sh" "$@"; }

# Cmd+K outside the cockpit: the terminal sends the key code \e[5000~ (see install.sh);
# clear the screen and the terminal's own scrollback. Inside the cockpit tmux catches it.
bind -x '"\e[5000~": "printf \"\\033[H\\033[2J\\033[3J\""' 2>/dev/null

# ── prompt ───────────────────────────────────────────────────────────────
# Starship draws the same prompt in bash. Without it, your own bash prompt is kept.
if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="$VICKS_HOME/starship.toml"
  eval "$(starship init bash)"
fi

# ── cockpit or banner ────────────────────────────────────────────────────
if ! command -v zsh >/dev/null 2>&1; then
  echo "vicks: the banner needs zsh. Run $VICKS_HOME/install.sh to install what is missing."
  return 0
fi

_vicks_wants_cockpit() {
  [ "${VICKS_AUTO_COCKPIT:-1}" != 0 ] || return 1
  [ -t 0 ] && [ -t 1 ] || return 1
  [ -z "${TMUX:-}" ] && [ -z "${VICKS_IN_COCKPIT:-}" ] && [ -z "${BASH_EXECUTION_STRING:-}" ] || return 1
  [ "${TERM_PROGRAM:-}" != vscode ] && [ -z "${INSIDE_EMACS:-}" ] || return 1
  case ${TERMINAL_EMULATOR:-} in JetBrains*) return 1 ;; esac
  # bash may not know the window size this early, so ask the terminal
  local rows cols
  read -r rows cols < <(stty size 2>/dev/null)
  [ "${rows:-0}" -ge 30 ] && [ "${cols:-0}" -ge 80 ] || return 1
  command -v tmux >/dev/null 2>&1
}

if _vicks_wants_cockpit; then
  _vicks_t0=$SECONDS
  if cockpit && [ $(( SECONDS - _vicks_t0 )) -ge 3 ]; then
    exit        # the terminal *was* the cockpit: leaving it closes the terminal
  fi
  # tmux failed or ended at once: never lock the user out, fall back to a plain shell
  echo "The cockpit did not start. This is a normal shell. Set VICKS_AUTO_COCKPIT=0 in ~/.bashrc to stop trying."
  unset _vicks_t0
elif [ -z "${VICKS_NO_BANNER:-}" ] && [ -t 1 ]; then
  hello --new-window ${VICKS_NO_NET:+--no-net}
fi
