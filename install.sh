#!/usr/bin/env bash
# install.sh — wire the banner and prompt into ~/.zshrc. Safe to run repeatedly.
#   ./install.sh              install
#   ./install.sh --uninstall  remove the block from ~/.zshrc
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
BEGIN="# >>> vicks-prompt-hello-world >>>"
END="# <<< vicks-prompt-hello-world <<<"

remove_block() {
  [[ -f "$ZSHRC" ]] || return 0
  if grep -qF "$BEGIN" "$ZSHRC"; then
    cp "$ZSHRC" "$ZSHRC.vicks-backup"
    sed -i.tmp "/^$BEGIN\$/,/^$END\$/d" "$ZSHRC" && rm -f "$ZSHRC.tmp"
  fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
  remove_block
  echo "Removed from $ZSHRC (backup at $ZSHRC.vicks-backup). Open a new terminal."
  exit 0
fi

# 1. Starship (the prompt). Without it, a pure-zsh fallback prompt is used.
if ! command -v starship >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing starship with Homebrew..."
    brew install starship
  else
    echo "Starship not found and Homebrew is missing; the fallback zsh prompt will be used."
    echo "To get Starship later: https://starship.rs/guide/#step-1-install-starship"
  fi
fi

# 2. Hook into ~/.zshrc (replace any previous block so the path stays current).
remove_block
touch "$ZSHRC"
{
  echo "$BEGIN"
  echo "[ -r \"$REPO/vicks.zsh\" ] && source \"$REPO/vicks.zsh\""
  echo "$END"
} >> "$ZSHRC"

chmod +x "$REPO/banner.zsh"
echo "Installed. Open a new terminal, or run:  source $ZSHRC"
