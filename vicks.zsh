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
#   VICKS_CLAUDE_COLOR=blue     colour of every new Claude Code session (unset: random, 0: none)

[[ -o interactive ]] || return 0

export VICKS_HOME=${${(%):-%x}:A:h}
export VIRTUAL_ENV_DISABLE_PROMPT=1   # the prompt shows the venv itself
# Who logged in to this terminal: the owner of the terminal device. That stays the
# same through sudo, su and tmux, so the prompt can flag commands run as someone else.
# (GNU stat first, then BSD stat; `logname` is not reliable everywhere.)
export VICKS_LOGIN_USER=${VICKS_LOGIN_USER:-$(stat -c %U "$TTY" 2>/dev/null || stat -f %Su "$TTY" 2>/dev/null)}
[[ -d $HOME/.local/bin && :$PATH: != *:$HOME/.local/bin:* ]] && PATH=$HOME/.local/bin:$PATH

# cmux hands each terminal a folder of small wrappers for claude and other agents
# ($CMUX_AGENT_COMMAND_SHIM_ROOT). Its wrapper is what tells cmux when an agent has
# finished, so the folder has to come first on the PATH. In a plain cmux terminal,
# cmux's own shell integration sees to that; inside tmux panes that integration does
# not run, and ~/.local/bin/claude would win. Put the folder of *this* terminal first
# and drop the ones inherited from other terminals through the tmux server.
_vicks_cmux_shims() {
  local root=${CMUX_AGENT_COMMAND_SHIM_ROOT:-${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}}
  [[ -n $root && -d $root ]] || return 0
  path=($root ${path:#*/cmux-cli-shims/*})
}
_vicks_cmux_shims
if [[ -n ${CMUX_AGENT_COMMAND_SHIM_ROOT:-${CMUX_CLAUDE_WRAPPER_SHIM_ROOT:-}} ]]; then
  # once more at the first prompt, in case something later in ~/.zshrc edits the PATH
  _vicks_cmux_shims_once() { _vicks_cmux_shims; add-zsh-hook -d precmd _vicks_cmux_shims_once; }
  autoload -Uz add-zsh-hook; add-zsh-hook precmd _vicks_cmux_shims_once
fi

# `hello` prints the banner any time; `hello --fresh` bypasses the network cache.
hello() { zsh "$VICKS_HOME/banner.zsh" "$@"; }

# `cockpit` opens tmux with the live banner in one pane and a shell in the other.
cockpit() { sh "$VICKS_HOME/cockpit.sh" "$@"; }

# `vicks-deploy user@host` copies this setup to a remote machine and installs it there.
# It is a real command: install.sh puts a launcher for deploy.sh in ~/.local/bin.

# `claude` gives every new session a colour. Claude Code has no setting for that, so a
# new interactive session gets /color as its first prompt, which picks a random colour
# and costs no turn. Everything else runs as typed: a prompt, a subcommand, -p, and
# resumed sessions, which keep the colour they had.
claude() {
  local a skip="" color=${VICKS_CLAUDE_COLOR:-}
  if [[ $color == 0 || ! -t 0 || ! -t 1 ]]; then command claude "$@"; return; fi
  for a in "$@"; do
    if [[ -n $skip ]]; then skip=""; continue; fi
    case $a in
      --model|--effort|--permission-mode|--settings|--agent|--name|-n) skip=1 ;;   # flags that take one value
      -p|--print|-c|--continue|-r|--resume*|--from-pr*|--teleport*|--cloud*|--bg|--background|--desktop| \
      --safe-mode|--disable-slash-commands|-h|--help|-v|--version|--) command claude "$@"; return ;;
      -*) ;;
      *) command claude "$@"; return ;;   # a prompt, a subcommand, or the value of a flag not listed above
    esac
  done
  if [[ -n $skip ]]; then command claude "$@"; return; fi
  command claude "$@" -- "/color${color:+ $color}"
}

# ── sidebar labels ───────────────────────────────────────────────────────
# Tell tmux which project this pane is in. tmux.conf turns that into the terminal
# title, and cmux shows the title as the workspace name in its left sidebar.
#   in a git repository:  repo, repo/sub, or repo/…/leaf
#   elsewhere:            ~ or the folder name
if [[ -n ${TMUX:-} && -n ${VICKS_IN_COCKPIT:-} ]]; then
  _vicks_label() {
    local root proj rel
    root=$(command git rev-parse --show-toplevel 2>/dev/null)
    if [[ -n $root ]]; then
      proj=${root:t}; rel=${${PWD#$root}#/}
      if [[ $rel == */* ]]; then proj+="/…/${rel:t}"
      elif [[ -n $rel ]]; then proj+="/$rel"; fi
    elif [[ $PWD == $HOME ]]; then proj="~"
    else proj=${PWD:t}
    fi
    tmux set-option -p @vicks_proj "$proj" 2>/dev/null
  }
  autoload -Uz add-zsh-hook
  add-zsh-hook chpwd _vicks_label     # only when the folder changes, so the prompt stays fast
  _vicks_label
fi

# `ssh` in a terminal marks the session where you can see it:
#   - the host goes into the terminal title ("⇄ host · project")
#   - in cmux, the workspace's sidebar row gets a red pill with the host name
#   - to a machine that vicks-deploy has set up, the local banner is hidden for the
#     length of the session, so the remote machine's banner takes its place
# All of it is undone when ssh returns. `cockpit.sh reconcile` sweeps pills left behind
# by a terminal that was closed mid-session.
ssh() {
  if [[ ! -t 1 || ( -z ${TMUX:-} && -z ${CMUX_WORKSPACE_ID:-} ) ]]; then command ssh "$@"; return; fi
  local h key="" unzoom=0
  h=$(command ssh -G "$@" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')
  if [[ -n $h ]]; then
    [[ -n ${TMUX:-} ]] && tmux set-option -p @vicks_ssh "$h" 2>/dev/null
    if [[ -n ${CMUX_WORKSPACE_ID:-} ]] && (( $+commands[cmux] )); then
      key="ssh-${${TMUX_PANE:-$$}#%}"      # one pill per terminal pane
      CMUX_QUIET=1 cmux set-status "$key" "$h" --icon server.rack --color "#ff3b30" --priority 90 \
        --workspace "$CMUX_WORKSPACE_ID" >/dev/null 2>&1
    fi
    if [[ -n ${VICKS_IN_COCKPIT:-} && -n ${TMUX:-} && -r $HOME/.config/vicks/remotes ]] \
       && grep -qxF -- "$h" "$HOME/.config/vicks/remotes" \
       && [[ $(tmux display-message -p '#{window_zoomed_flag}' 2>/dev/null) != 1 ]]; then
      tmux resize-pane -Z 2>/dev/null && unzoom=1
    fi
  fi
  command ssh "$@"; local rc=$?
  if [[ -n $h ]]; then
    (( unzoom )) && tmux resize-pane -Z 2>/dev/null
    [[ -n ${TMUX:-} ]] && tmux set-option -pu @vicks_ssh 2>/dev/null
    [[ -n $key ]] && ( CMUX_QUIET=1 cmux clear-status "$key" --workspace "$CMUX_WORKSPACE_ID" >/dev/null 2>&1 & )
  fi
  return $rc
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
