#!/usr/bin/env bash
# deploy.sh — copy this setup to a remote machine over SSH and install it there.
#
#   deploy.sh user@host               copy to ~/.vicks on the remote, then run its installer
#   deploy.sh user@host --deps        install missing packages there without asking
#   deploy.sh user@host --no-deps     never install packages there
#   deploy.sh user@host --uninstall   remove it from the remote again
#
# Nothing is needed on the remote beforehand except SSH access and tar. Run it again
# after changing anything here to update the remote copy.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ $# -lt 1 ] || [ "${1#-}" != "$1" ]; then
  echo "Usage: vicks-deploy user@host [--deps|--no-deps|--uninstall]"; exit 2
fi
HOST=$1; shift
REMOTES="$HOME/.config/vicks/remotes"
# the real hostname SSH connects to, after ~/.ssh/config is applied
RESOLVED=$(ssh -G "$HOST" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}')

if [ "${1:-}" = --uninstall ]; then
  ssh -t "$HOST" 'if [ -x ~/.vicks/install.sh ]; then ~/.vicks/install.sh --uninstall && rm -rf ~/.vicks; else echo "vicks is not installed here."; fi'
  if [ -n "$RESOLVED" ] && [ -f "$REMOTES" ]; then
    grep -vxF -- "$RESOLVED" "$REMOTES" > "$REMOTES.tmp"; mv "$REMOTES.tmp" "$REMOTES"
  fi
  exit 0
fi

FILES=(banner.zsh vicks.zsh vicks.bash cockpit.sh tmux.conf starship.toml prompt-fallback.zsh
       install.sh xwing.art xwing-small.art tie.art deathstar.art cmux-tips.txt README.md)

echo "Copying to $HOST:~/.vicks ..."
# COPYFILE_DISABLE keeps macOS metadata files out of the archive
COPYFILE_DISABLE=1 tar -C "$REPO" -czf - "${FILES[@]}" \
  | ssh "$HOST" 'mkdir -p ~/.vicks && tar -xzf - -C ~/.vicks 2>/dev/null && chmod +x ~/.vicks/*.sh ~/.vicks/banner.zsh' \
  || { echo "Copy failed. Check that 'ssh $HOST' works."; exit 1; }

echo "Running the installer on $HOST ..."
# -t gives the installer a terminal, so it can ask before installing packages with sudo
ssh -t "$HOST" "~/.vicks/install.sh $*" || { echo "The remote installer reported a problem."; exit 1; }

# remember this machine: ssh to it from the cockpit then swaps the local banner for the remote one
if [ -n "$RESOLVED" ]; then
  mkdir -p "$(dirname "$REMOTES")"; touch "$REMOTES"
  grep -qxF -- "$RESOLVED" "$REMOTES" || echo "$RESOLVED" >> "$REMOTES"
fi
echo "Done. ssh $HOST to see it. That machine shows a TIE fighter instead of the X-wing."
