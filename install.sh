#!/usr/bin/env bash
# install.sh — wire the banner and prompt into your shell. Safe to run repeatedly.
# Works on macOS (Homebrew) and Linux (apt, dnf, pacman, zypper, apk).
#
#   ./install.sh              install; asks before installing packages with sudo
#   ./install.sh --deps       install missing packages without asking
#   ./install.sh --no-deps    never install packages, only say what is missing
#   ./install.sh --no-claude  leave Claude Code alone: no /btw skill or hook, no CLAUDE.md
#                             block, no Remote Control setting (for machines where
#                             unattended agents run and must not pick up cockpit habits)
#   ./install.sh --uninstall  remove the block from ~/.zshrc and ~/.bashrc
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEGIN="# >>> vicks-prompt-hello-world >>>"
END="# <<< vicks-prompt-hello-world <<<"
DEPS=ask
ACTION=install
CLAUDE=yes
for a in "$@"; do
  case $a in
    --deps)      DEPS=yes ;;
    --no-deps)   DEPS=no ;;
    --no-claude) CLAUDE=no ;;
    --uninstall) ACTION=uninstall ;;
  esac
done

remove_block() {   # remove_block <file> [begin-line end-line]
  local begin=${2:-$BEGIN} end=${3:-$END}
  [ -f "$1" ] || return 0
  if grep -qF "$begin" "$1"; then
    cp "$1" "$1.vicks-backup"
    sed -i.tmp "/^$begin\$/,/^$end\$/d" "$1" && rm -f "$1.tmp"
  fi
}

ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
BASHRC="$HOME/.bashrc"

# Claude Code: the /btw skill, its hook and Remote Control in settings.json, and a
# marked block in CLAUDE.md
CLAUDE_DIR="$HOME/.claude"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
CLAUDE_SETTINGS="$CLAUDE_DIR/settings.json"
MD_BEGIN="<!-- >>> vicks-prompt-hello-world >>> -->"
MD_END="<!-- <<< vicks-prompt-hello-world <<< -->"
BTW_HOOK='sh ~/.claude/skills/btw/btw-side.sh hook'

remove_btw_hook() {   # take the /btw hook out of settings.json, and the keys it leaves empty
  [ -f "$CLAUDE_SETTINGS" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -e --arg cmd "$BTW_HOOK" 'any(.hooks.UserPromptExpansion[]?.hooks[]?; .command == $cmd)' \
    "$CLAUDE_SETTINGS" >/dev/null 2>&1 || return 0
  jq --arg cmd "$BTW_HOOK" '
    .hooks.UserPromptExpansion |= map(select(any(.hooks[]?; .command == $cmd) | not))
    | if .hooks.UserPromptExpansion == [] then del(.hooks.UserPromptExpansion) else . end
    | if .hooks == {} then del(.hooks) else . end' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" \
    && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
}

remove_remote_control() {   # take remoteControlAtStartup out of settings.json again
  [ -f "$CLAUDE_SETTINGS" ] && command -v jq >/dev/null 2>&1 || return 0
  jq -e '.remoteControlAtStartup == true' "$CLAUDE_SETTINGS" >/dev/null 2>&1 || return 0
  jq 'del(.remoteControlAtStartup)' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp" \
    && mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
}

if [ "$ACTION" = uninstall ]; then
  remove_block "$ZSHRC"; remove_block "$BASHRC"
  for f in "$HOME/Library/Application Support/com.mitchellh.ghostty/config.ghostty" \
           "$HOME/Library/Application Support/com.mitchellh.ghostty/config" \
           "$HOME/.config/ghostty/config.ghostty" "$HOME/.config/ghostty/config"; do
    remove_block "$f"
  done
  remove_block "$HOME/.config/cmux/cmux.json" "  // >>> vicks-prompt-hello-world >>>" "  // <<< vicks-prompt-hello-world <<<"
  remove_block "$CLAUDE_MD" "$MD_BEGIN" "$MD_END"
  remove_btw_hook
  remove_remote_control
  rm -f "$CLAUDE_DIR/skills/btw/SKILL.md" "$CLAUDE_DIR/skills/btw/btw-side.sh"
  rmdir "$CLAUDE_DIR/skills/btw" 2>/dev/null
  rm -f "$HOME/.local/bin/vicks-deploy"
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
    for tool in starship tmux iperf3; do
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
    if [ -n "$SUDO" ] && ! command -v sudo >/dev/null 2>&1; then
      # locked-down machines and containers: packages have to come from whoever builds the machine
      echo "This account cannot install packages (no sudo here)."
      echo "Add these packages to the machine or its image, then run this again:${pkgs:-$missing}"
    elif [ -z "$cmd" ]; then
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

# ── 1c. Cmd+K in Ghostty-based terminals (Ghostty, cmux) ────────────────
# By default Cmd+K wipes the terminal's own buffer, which tmux never hears about, so
# the pinned view goes blank. Send a private key code instead; tmux.conf and the shell
# entry points turn it into a proper clear.
if [ "$(uname -s)" = Darwin ]; then
  GDIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
  GCONF=""
  for f in "$GDIR/config.ghostty" "$GDIR/config" "$HOME/.config/ghostty/config.ghostty" "$HOME/.config/ghostty/config"; do
    [ -f "$f" ] && { GCONF="$f"; break; }
  done
  if [ -n "$GCONF" ]; then
    remove_block "$GCONF"
    {
      echo "$BEGIN"
      echo "# Cmd+K: send a key code that the pinned banner turns into a proper clear"
      echo "keybind = super+k=csi:5000~"
      echo "$END"
    } >> "$GCONF"
    echo "Cmd+K remapped in $GCONF. Reload the terminal's configuration or restart it to apply."
  fi
fi

# ── 1d. cmux shortcuts ───────────────────────────────────────────────────
# Adds cmux/shortcuts.jsonc to ~/.config/cmux/cmux.json, once. Skipped when the file
# already has an active "shortcuts" section, so your own bindings are never replaced.
CMUX_JSON="$HOME/.config/cmux/cmux.json"
if [ -f "$CMUX_JSON" ] && [ -f "$REPO/cmux/shortcuts.jsonc" ]; then
  if grep -qE '^[[:space:]]*"shortcuts"[[:space:]]*:' "$CMUX_JSON"; then
    :   # already has shortcuts (ours or yours)
  elif grep -qE '^[[:space:]]*"schemaVersion"' "$CMUX_JSON"; then
    cp "$CMUX_JSON" "$CMUX_JSON.vicks-backup"
    awk -v f="$REPO/cmux/shortcuts.jsonc" '
      { print }
      !done && /^[[:space:]]*"schemaVersion"/ { print ""; while ((getline line < f) > 0) print line; done = 1 }
    ' "$CMUX_JSON.vicks-backup" > "$CMUX_JSON"
    echo "cmux: browser split shortcuts added to $CMUX_JSON (cmd+shift+b below, cmd+ctrl+b right)."
  fi
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

chmod +x "$REPO/banner.zsh" "$REPO/cockpit.sh" "$REPO/deploy.sh" 2>/dev/null

# ── 3. vicks-deploy as a real command ────────────────────────────────────
# A small launcher in ~/.local/bin, so it works in every shell, scripts included,
# and not only in interactive terminals where the shell functions are loaded.
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\nexec bash "%s/deploy.sh" "$@"\n' "$REPO" > "$HOME/.local/bin/vicks-deploy"
chmod +x "$HOME/.local/bin/vicks-deploy"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Note: ~/.local/bin is not on your PATH in this shell; new terminals add it." ;;
esac

# ── 4. Claude Code: /btw in a side pane, and how to show work in the cockpit ──
# Only where Claude Code is set up. The skill takes over the built-in /btw; the hook
# opens the side pane without the asking session spending a turn on it; the CLAUDE.md
# block tells Claude to show its sub-tasks in tmux panes of the cockpit. Remote Control
# is switched on for every session. (The session colour needs no install step: the
# `claude` function in vicks.zsh and vicks.bash sets it.)
if [ "$CLAUDE" = yes ] && [ -d "$CLAUDE_DIR" ]; then
  mkdir -p "$CLAUDE_DIR/skills/btw"
  cp "$REPO/claude/btw/SKILL.md" "$REPO/claude/btw/btw-side.sh" "$CLAUDE_DIR/skills/btw/"
  chmod +x "$CLAUDE_DIR/skills/btw/btw-side.sh"

  remove_block "$CLAUDE_MD" "$MD_BEGIN" "$MD_END"
  # the block has to start on a line of its own, or the next run cannot find it
  [ -s "$CLAUDE_MD" ] && [ -n "$(tail -c1 "$CLAUDE_MD")" ] && echo >> "$CLAUDE_MD"
  { echo "$MD_BEGIN"; cat "$REPO/claude/cockpit-rules.md"; echo "$MD_END"; } >> "$CLAUDE_MD"

  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is missing, so the /btw hook was not added to $CLAUDE_SETTINGS. Install jq and run this again."
  else
    [ -s "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
    if jq -e --arg cmd "$BTW_HOOK" 'any(.hooks.UserPromptExpansion[]?.hooks[]?; .command == $cmd)' \
         "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
      :   # already there
    elif jq --arg cmd "$BTW_HOOK" '.hooks.UserPromptExpansion += [{hooks: [{type: "command", command: $cmd}]}]' \
           "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp"; then
      mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
    else
      rm -f "$CLAUDE_SETTINGS.tmp"
      echo "Could not read $CLAUDE_SETTINGS, so the /btw hook was not added."
    fi
    # Remote Control (/rc) in every session, unless settings.json already says either way
    if jq -e 'has("remoteControlAtStartup") | not' "$CLAUDE_SETTINGS" >/dev/null 2>&1; then
      if jq '.remoteControlAtStartup = true' "$CLAUDE_SETTINGS" > "$CLAUDE_SETTINGS.tmp"; then
        mv "$CLAUDE_SETTINGS.tmp" "$CLAUDE_SETTINGS"
        echo "Claude Code: Remote Control is now on for every session (remoteControlAtStartup in $CLAUDE_SETTINGS)."
      else
        rm -f "$CLAUDE_SETTINGS.tmp"
      fi
    fi
  fi
  echo "Claude Code: /btw now opens a side pane. Restart running Claude sessions to pick it up."
fi

echo "Installed into $RC. Open a new terminal (or log in again) to see it."
