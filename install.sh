#!/usr/bin/env bash
# install.sh — wire the banner and prompt into your shell. Safe to run repeatedly.
# Works on macOS (Homebrew) and Linux (apt, dnf, pacman, zypper, apk).
#
#   ./install.sh              install; asks before installing packages with sudo
#   ./install.sh --deps       install missing packages without asking
#   ./install.sh --no-deps    never install packages, only say what is missing
#   ./install.sh --uninstall  remove the block from ~/.zshrc and ~/.bashrc
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEGIN="# >>> vicks-prompt-hello-world >>>"
END="# <<< vicks-prompt-hello-world <<<"
DEPS=ask
ACTION=install
for a in "$@"; do
  case $a in
    --deps)      DEPS=yes ;;
    --no-deps)   DEPS=no ;;
    --uninstall) ACTION=uninstall ;;
  esac
done

remove_block() {   # remove_block <rcfile>
  [ -f "$1" ] || return 0
  if grep -qF "$BEGIN" "$1"; then
    cp "$1" "$1.vicks-backup"
    sed -i.tmp "/^$BEGIN\$/,/^$END\$/d" "$1" && rm -f "$1.tmp"
  fi
}

ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
BASHRC="$HOME/.bashrc"

if [ "$ACTION" = uninstall ]; then
  remove_block "$ZSHRC"; remove_block "$BASHRC"
  echo "Removed the vicks block from your shell startup files. Open a new terminal."
  exit 0
fi

confirm() {   # confirm "question" -> 0 for yes
  [ "$DEPS" = yes ] && return 0
  [ "$DEPS" = no ] && return 1
  [ -t 0 ] || return 1
  printf '%s [Y/n] ' "$1"; read -r reply
  case $reply in ""|y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

# ── 1. tools ─────────────────────────────────────────────────────────────
# zsh runs the banner, tmux pins it, jq/curl/traceroute/dig feed the network sections,
# starship draws the prompt.
if [ "$(uname -s)" = Darwin ]; then
  if command -v brew >/dev/null 2>&1; then
    for tool in starship tmux; do
      command -v "$tool" >/dev/null 2>&1 || { echo "Installing $tool with Homebrew..."; brew install "$tool"; }
    done
  else
    echo "Homebrew is missing, so starship and tmux were not installed."
    echo "The banner still works; the pinned cockpit needs tmux."
  fi
else
  missing=""
  for tool in zsh tmux jq curl traceroute dig; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo "
    if   command -v apt-get >/dev/null 2>&1; then pkgs=${missing/ dig/ dnsutils};   cmd="${SUDO}apt-get update -qq && ${SUDO}apt-get install -y$pkgs"
    elif command -v dnf     >/dev/null 2>&1; then pkgs=${missing/ dig/ bind-utils}; cmd="${SUDO}dnf install -y$pkgs"
    elif command -v pacman  >/dev/null 2>&1; then pkgs=${missing/ dig/ bind};       cmd="${SUDO}pacman -S --noconfirm$pkgs"
    elif command -v zypper  >/dev/null 2>&1; then pkgs=${missing/ dig/ bind-utils}; cmd="${SUDO}zypper install -y$pkgs"
    elif command -v apk     >/dev/null 2>&1; then pkgs=${missing/ dig/ bind-tools}; cmd="${SUDO}apk add$pkgs"
    else cmd=""; fi
    echo "Missing tools:$missing"
    if [ -z "$cmd" ]; then
      echo "No known package manager found. Install them by hand, then run this again."
    elif confirm "Install them now with: $cmd ?"; then
      sh -c "$cmd" || echo "Package install failed. Run it by hand: $cmd"
    else
      echo "Skipped. To install them later: $cmd"
    fi
  fi
  if ! command -v starship >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/starship" ]; then
    if command -v curl >/dev/null 2>&1 && \
       confirm "Install the Starship prompt into ~/.local/bin with its official installer (starship.rs)?"; then
      mkdir -p "$HOME/.local/bin"
      curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin" >/dev/null \
        || echo "Starship install failed. The banner works without it."
    else
      echo "Starship not installed. The banner works without it; the prompt stays as it is."
    fi
  fi
  command -v zsh >/dev/null 2>&1 || echo "Warning: zsh is still missing, and the banner cannot run without it."
fi

# ── 2. hook into the login shell ─────────────────────────────────────────
# Replace any previous block so the path stays current.
case "$(basename "${SHELL:-}")" in
  bash) RC="$BASHRC"; ENTRY="$REPO/vicks.bash" ;;
  *)    RC="$ZSHRC";  ENTRY="$REPO/vicks.zsh" ;;
esac
remove_block "$RC"
touch "$RC"
{
  echo "$BEGIN"
  echo "[ -r \"$ENTRY\" ] && source \"$ENTRY\""
  echo "$END"
} >> "$RC"

chmod +x "$REPO/banner.zsh" "$REPO/cockpit.sh" 2>/dev/null
echo "Installed into $RC. Open a new terminal (or log in again) to see it."
