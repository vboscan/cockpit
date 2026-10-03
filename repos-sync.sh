#!/usr/bin/env bash
# repos-sync.sh — make sure each repo is cloned under a folder and current on main.
# Run by repos.zsh, on this machine and (piped over SSH) on the remote one.
#
#   repos-sync.sh <folder> <owner/repo>...
#
# Prints one line per repo:  name|state|detail|path
#   cloned   was missing, now cloned
#   updated  main moved forward
#   current  main already matches GitHub
#   held     main is behind but was left alone (uncommitted changes, or it has diverged)
#   failed   clone or fetch did not work
# It only ever fast-forwards: nothing is stashed, reset or overwritten.
set -u
export GIT_TERMINAL_PROMPT=0

base=$1; shift
case $base in "~"*) base=$HOME${base#"~"} ;; esac

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# find_clone <owner/repo>  -> the folder whose origin is that repo, whatever its name
find_clone() {
  local want d url
  want=$(lower "$1")
  for d in "$base"/*/; do
    [ -e "$d.git" ] || continue
    url=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
    url=$(lower "$url"); url=${url%/}; url=${url%.git}
    case $url in *[:/]"$want") printf '%s' "${d%/}"; return ;; esac
  done
}

for repo in "$@"; do
  name=${repo##*/}
  dir=$(find_clone "$repo")
  if [ -z "$dir" ]; then
    dir=$base/$name
    if [ -e "$dir" ]; then echo "$name|failed|$dir exists but is not a clone of $repo|"; continue; fi
    if git clone -q "https://github.com/$repo.git" "$dir" 2>/dev/null; then echo "$name|cloned||$dir"
    else echo "$name|failed|clone failed|"; fi
    continue
  fi
  if ! git -C "$dir" fetch -q origin 2>/dev/null; then echo "$name|failed|fetch failed|$dir"; continue; fi
  if ! git -C "$dir" rev-parse -q --verify origin/main >/dev/null; then echo "$name|failed|no main branch on GitHub|$dir"; continue; fi
  branch=$(git -C "$dir" branch --show-current)
  note=""; [ "$branch" != main ] && note="on ${branch:-a detached commit}"
  if ! git -C "$dir" rev-parse -q --verify main >/dev/null; then
    git -C "$dir" branch -q main origin/main 2>/dev/null
  fi
  behind=$(git -C "$dir" rev-list --count main..origin/main 2>/dev/null || echo 0)
  ahead=$(git -C "$dir" rev-list --count origin/main..main 2>/dev/null || echo 0)
  if [ "$behind" -eq 0 ]; then
    [ "$ahead" -gt 0 ] && note="${note:+$note, }$ahead not pushed"
    echo "$name|current|$note|$dir"
  elif [ "$ahead" -gt 0 ]; then
    echo "$name|held|main has diverged: $ahead not pushed, $behind behind|$dir"
  elif [ "$branch" = main ]; then
    if [ -n "$(git -C "$dir" status --porcelain -uno)" ]; then
      echo "$name|held|$behind behind, uncommitted changes|$dir"
    elif git -C "$dir" merge -q --ff-only origin/main >/dev/null 2>&1; then
      echo "$name|updated|$behind new|$dir"
    else
      echo "$name|held|$behind behind, could not fast-forward|$dir"
    fi
  elif git -C "$dir" fetch -q . origin/main:main 2>/dev/null; then
    echo "$name|updated|$behind new, $note|$dir"
  else
    echo "$name|held|$behind behind, $note|$dir"
  fi
done
