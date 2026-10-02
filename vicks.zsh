# vicks.zsh — entry point, sourced from ~/.zshrc (install.sh adds the line).
# Sets up the prompt and shows the welcome banner on every new interactive shell.
#
# Opt-outs:  export VICKS_NO_BANNER=1   (no banner)
#            export VICKS_NO_NET=1      (banner without public IP / traceroute)

[[ -o interactive ]] || return 0

export VICKS_HOME=${${(%):-%x}:A:h}
export VIRTUAL_ENV_DISABLE_PROMPT=1   # the prompt shows the venv itself

# `hello` re-runs the banner any time; `hello --fresh` bypasses the network cache.
hello() { zsh "$VICKS_HOME/banner.zsh" "$@"; }

# ── prompt ───────────────────────────────────────────────────────────────
if command -v starship >/dev/null 2>&1; then
  export STARSHIP_CONFIG="$VICKS_HOME/starship.toml"
  eval "$(starship init zsh)"
else
  source "$VICKS_HOME/prompt-fallback.zsh"
fi

# ── banner ───────────────────────────────────────────────────────────────
if [[ -z ${VICKS_NO_BANNER:-} && -t 1 ]]; then
  hello ${VICKS_NO_NET:+--no-net}
fi
