# vicks.zsh — entry point for zsh, sourced from ~/.zshrc (install.sh adds the line).
# Sets up the prompt. Every new terminal then runs inside tmux (the "cockpit"), and
# one terminal per cmux workspace also shows the pinned, self-updating banner.
#
# Commands:  hello [--fresh|--no-net]   print the full banner once
#            cockpit here               move the banner into this terminal
#            cockpit refresh            look everything up again right now
#            vicks-deploy user@host     install all of this on a remote machine
#
# Settings (export them in ~/.zshrc above the vicks block):
#   VICKS_PLAIN=1          a raw shell: no tmux and no banner (prompt and commands stay)
#   VICKS_AUTO_COCKPIT=0   no tmux; new terminals print the one-off banner instead
#   VICKS_COCKPIT_LAYOUT=side   pinned banner in a right-hand column instead of on top
#   VICKS_REMOTE_ART=deathstar  ship shown when reached over SSH (tie, deathstar, xwing)
#   VICKS_NO_BANNER=1      no banner at all on new shells
#   VICKS_NO_NET=1         banner without public IP / traceroute

[[ -o interactive ]] || return 0

export VICKS_HOME=${${(%):-%x}:A:h}
export VIRTUAL_ENV_DISABLE_PROMPT=1   # the prompt shows the venv itself
# Who logged in to this terminal: the owner of the terminal device. That stays the
# same through sudo, su and tmux, so the prompt can flag commands run as someone else.
# (GNU stat first, then BSD stat; `logname` is not reliable everywhere.)
export VICKS_LOGIN_USER=${VICKS_LOGIN_USER:-$(stat -c %U "$TTY" 2>/dev/null || stat -f %Su "$TTY" 2>/dev/null)}
[[ -d $HOME/.local/bin && :$PATH: != *:$HOME/.local/bin:* ]] && PATH=$HOME/.local/bin:$PATH

# `hello` prints the banner any time; `hello --fresh` bypasses the network cache.
hello() { zsh "$VICKS_HOME/banner.zsh" "$@"; }

# `cockpit` opens tmux with the live banner in one pane and a shell in the other.
cockpit() { sh "$VICKS_HOME/cockpit.sh" "$@"; }

# `vicks-deploy user@host` copies this setup to a remote machine and installs it there.
# It is a real command: install.sh puts a launcher for deploy.sh in ~/.local/bin.

# Inside the cockpit, `ssh` to a machine that vicks-deploy has set up hides the local
# banner for the length of the session, so the remote machine's banner takes its place.
ssh() {
  if [[ -n ${VICKS_IN_COCKPIT:-} && -n ${TMUX:-} && -t 1 && -r $HOME/.config/vicks/remotes ]]; then
    local h; h=$(command ssh -G "$@" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')
    if [[ -n $h ]] && grep -qxF -- "$h" "$HOME/.config/vicks/remotes"; then
      local zoomed; zoomed=$(tmux display-message -p '#{window_zoomed_flag}' 2>/dev/null)
      [[ $zoomed == 1 ]] || tmux resize-pane -Z 2>/dev/null
      command ssh "$@"; local rc=$?
      [[ $zoomed == 1 ]] || tmux resize-pane -Z 2>/dev/null
      return $rc
    fi
  fi
  command ssh "$@"
}

# Cmd+K outside the cockpit: the terminal sends the key code \e[5000~ (see install.sh),
# and this clears the screen and the terminal's own scrollback. Inside the cockpit
# tmux catches the key code first (tmux.conf).
_vicks_clear() { print -n '\e[H\e[2J\e[3J'; zle reset-prompt; }
zle -N _vicks_clear
bindkey '\e[5000~' _vicks_clear

# ── prompt ───────────────────────────────────────────────────────────────
if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="$VICKS_HOME/starship.toml"
  eval "$(starship init zsh)"
else
  source "$VICKS_HOME/prompt-fallback.zsh"
fi

# ── cockpit or banner ────────────────────────────────────────────────────
# The cockpit (tmux) starts by itself in real terminal windows: not inside tmux, not
# for `zsh -c`, not in IDE or app terminal panels, and not when switched off.
#   - inside cmux: every terminal, whatever its size, so the banner can move between
#     the terminals of a workspace. `cockpit.sh reconcile` decides which one shows it.
#   - anywhere else: only roomy windows (80x30 or more), as before. That keeps tmux out
#     of small embedded terminals that this file cannot recognise by name.
_vicks_wants_cockpit() {
  [[ ${VICKS_AUTO_COCKPIT:-1} != 0 && -z ${VICKS_PLAIN:-} ]] || return 1
  [[ -t 0 && -t 1 ]] || return 1
  [[ -z ${TMUX:-} && -z ${VICKS_IN_COCKPIT:-} && -z ${ZSH_EXECUTION_STRING:-} ]] || return 1
  [[ ${TERM_PROGRAM:-} != vscode && -z ${INSIDE_EMACS:-} && ${TERMINAL_EMULATOR:-} != JetBrains* ]] || return 1
  [[ ${__CFBundleIdentifier:-} != com.anthropic.claudefordesktop ]] || return 1   # the Claude app's terminal panel
  if [[ -z ${CMUX_WORKSPACE_ID:-} ]]; then
    (( ${LINES:-0} >= 30 && ${COLUMNS:-0} >= 80 )) || return 1
  fi
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
elif [[ -z ${VICKS_NO_BANNER:-} && -z ${VICKS_PLAIN:-} && -t 1 ]]; then
  hello --new-window ${VICKS_NO_NET:+--no-net}
fi
