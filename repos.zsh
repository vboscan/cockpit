#!/usr/bin/env zsh
# repos.zsh — keep the repos in repos.conf cloned and current on main, on this Mac and
# on the remote machine, and give each one a cmux workspace.
#
#   repos.zsh             sync both machines, add missing workspaces, print a report
#   repos.zsh --summary   the same, but print one line (the banner's "Repos" row)
#   repos.zsh --no-cmux   sync only
#
# The banner runs it in the background every 30 minutes (VICKS_REPOS_TTL). The last
# full report is kept in ~/.cache/vicks/repos_report.
#
# Workspaces: one per repo, in a "Local" group for this Mac and a group named after the
# remote host. A workspace is recognised by its description ("cockpit · this Mac"), so
# renaming one is fine, and one you close comes back on the next run. Nothing is ever
# closed. cmux only talks to processes started inside it, so this part is skipped when
# the script runs from anywhere else.
typeset -g here=${0:A:h}

main() {
emulate -L zsh
setopt pipefail

local conf=${VICKS_REPOS_CONF:-$here/repos.conf}
local cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/vicks
local local_base=${VICKS_REPOS_DIR:-$HOME/Git}
local summary=0 use_cmux=1 a
for a in "$@"; do
  case $a in
    --summary) summary=1 ;;
    --no-cmux) use_cmux=0 ;;
  esac
done
[[ -r $conf ]] || { print -u2 "repos: $conf not found"; return 1; }
mkdir -p "$cache_dir"

local remote="" remote_base="~" line repo
local -a local_repos remote_repos words
for line in "${(@f)$(<$conf)}"; do
  words=(${=line%%\#*})
  (( $#words )) || continue
  if [[ $words[1] == remote ]]; then remote=$words[2]; remote_base=${words[3]:-"~"}; continue; fi
  repo=$words[1]
  (( ${words[(Ie)local]} ))  && local_repos+=($repo)
  (( ${words[(Ie)remote]} )) && remote_repos+=($repo)
done
local remote_name=${${remote#*@}%%.*}

# ------------------------------------------------------------------- sync ---
local -a local_out remote_out
local remote_err=""
(( $#local_repos )) && local_out=("${(@f)$(bash "$here/repos-sync.sh" "$local_base" $local_repos 2>/dev/null)}")
if [[ -n $remote ]] && (( $#remote_repos )); then
  remote_out=("${(@f)$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote" \
    "bash -s -- ${(q)remote_base} ${(j: :)${(q)remote_repos[@]}}" < "$here/repos-sync.sh" 2>/dev/null)}")
  (( $#remote_out )) && [[ -n $remote_out[1] ]] || { remote_out=(); remote_err="$remote_name unreachable"; }
fi

# ------------------------------------------------------------- workspaces ---
# ensure_ws <group-name> <group-id> <label> <kind> <result-line>...
local -a ws_new
ensure_ws() {
  local gname=$1 gid=$2 label=$3 kind=$4; shift 4
  local group="" have r name state detail dir desc ref
  have="$(cmux workspace list --json 2>/dev/null | jq -r '.workspaces[].description // empty')" || return
  for r in "$@"; do
    IFS='|' read -r name state detail dir <<< "$r"
    [[ -n $dir ]] || continue
    desc="$name · $label"
    [[ $'\n'$have$'\n' == *$'\n'$desc$'\n'* ]] && continue
    if [[ -z $group ]]; then
      group=$(cmux workspace-group create --name "$gname" --external-id "$gid" --cwd "$local_base" --json 2>/dev/null | jq -r '.group.ref // empty')
      [[ -n $group ]] || return
    fi
    if [[ $kind == local ]]; then
      cmux new-workspace --name "$name" --description "$desc" --cwd "$dir" --focus false \
        --group "$group" --group-placement end >/dev/null 2>&1 && ws_new+=("$desc")
    else
      # cmux ssh has no group or description flags, so those are set on the new workspace
      cmux ssh "$remote" --name "$name" --command "cd ${(q)dir}" --no-focus >/dev/null 2>&1 || continue
      ref=$(cmux workspace list --json 2>/dev/null | jq -r --arg t "$name" --arg d "$remote" \
        '[.workspaces[] | select(.title == $t and .remote.destination == $d and (.description // "") == "")][0].ref // empty')
      [[ -n $ref ]] || continue
      cmux workspace-action --workspace "$ref" --action set-description --description "$desc" >/dev/null 2>&1
      cmux workspace-group add --group "$group" --workspace "$ref" >/dev/null 2>&1
      ws_new+=("$desc")
    fi
  done
}
export CMUX_QUIET=1
if (( use_cmux && $+commands[cmux] && $+commands[jq] )) && cmux workspace list --json >/dev/null 2>&1; then
  ensure_ws Local vicks-repos-local "this Mac" local "${local_out[@]}"
  [[ -n $remote ]] && ensure_ws "${(C)${remote_name%-<->}}" vicks-repos-remote "$remote_name" remote "${remote_out[@]}"
fi

# ----------------------------------------------------------------- report ---
local r name state detail dir where
local -A n
local -a attention
{
  print "Repos, checked $(date '+%a %d %b %H:%M')"
  for where in "this Mac" "$remote_name"; do
    [[ $where == "this Mac" ]] && set -- "${local_out[@]}" || set -- "${remote_out[@]}"
    (( $# )) || continue
    print; print "$where"
    for r in "$@"; do
      IFS='|' read -r name state detail dir <<< "$r"
      [[ -n $name ]] || continue
      (( n[$state]++ )); (( n[total]++ ))
      printf "  %-22s %-8s %s\n" "$name" "$state" "$detail"
      [[ $state == (held|failed) ]] && attention+=("$name ($where)")
    done
  done
  [[ -n $remote_err ]] && { print; print "$remote_err: nothing checked there"; }
  (( $#ws_new )) && { print; print "New cmux workspaces: ${(j:, :)ws_new}"; }
} > "$cache_dir/repos_report.tmp.$$"
mv -f "$cache_dir/repos_report.tmp.$$" "$cache_dir/repos_report"

if (( summary )); then
  local s="${n[total]:-0} checked"
  (( ${n[cloned]:-0} ))  && s+=" · ${n[cloned]} cloned"
  (( ${n[updated]:-0} )) && s+=" · ${n[updated]} updated"
  (( $#attention ))      && s+=" · needs you: ${(j:, :)attention}"
  [[ -n $remote_err ]]   && s+=" · $remote_err"
  print -r -- "$s"
else
  cat "$cache_dir/repos_report"
fi
}
main "$@"
