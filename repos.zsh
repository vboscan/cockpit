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
# closed. A remote workspace that reconnected into ~ is sent back to its repo while its
# shell sits idle there, and joins the repo's Claude session when the remote machine
# keeps one in a tmux session of the repo's name. cmux only talks to processes started inside it, so this part is skipped when
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
  # The chmod keeps cmux working there: its remote side refuses to keep session state under
  # ~/.local/state while that or ~/.local is group-writable, which a 0002 umask makes them.
  remote_out=("${(@f)$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote" \
    "chmod go-w ~/.local ~/.local/state 2>/dev/null; bash -s -- ${(q)remote_base} ${(j: :)${(q)remote_repos[@]}}" \
    < "$here/repos-sync.sh" 2>/dev/null)}")
  (( $#remote_out )) && [[ -n $remote_out[1] ]] || { remote_out=(); remote_err="$remote_name unreachable"; }
fi

# ------------------------------------------------------------- workspaces ---
# open_cmd <dir>: what a remote workspace runs to open its repo. The devbox keeps one
# Claude session per repo in a tmux session named after the checkout; attach to it if
# there is one. Detaching (Ctrl-b d) leaves a shell in the repo.
open_cmd() {
  local n=${(q)1:t}
  REPLY="cd ${(q)1} && if tmux has-session -t =$n 2>/dev/null; then tmux attach -t =$n; fi"
}
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
      open_cmd "$dir"
      cmux ssh "$remote" --name "$name" --command "$REPLY" --no-focus >/dev/null 2>&1 || continue
      ref=$(cmux workspace list --json 2>/dev/null | jq -r --arg t "$name" --arg d "$remote" \
        '[.workspaces[] | select(.title == $t and .remote.destination == $d and (.description // "") == "")][0].ref // empty')
      [[ -n $ref ]] || continue
      cmux workspace-action --workspace "$ref" --action set-description --description "$desc" >/dev/null 2>&1
      cmux workspace-group add --group "$group" --workspace "$ref" >/dev/null 2>&1
      ws_new+=("$desc")
    fi
  done
}
# recd_ws <result-line>...
# A remote workspace's `cd` (the --command above) runs in its first shell only, so after
# a reconnect cmux starts a fresh shell in ~. This sends it again, but only to a
# workspace with a single terminal whose remote shells are all idle at a prompt in ~:
# cmux does not say which remote shell a surface shows, and keystrokes must never land
# in a running program.
local -a ws_recd
recd_ws() {
  local r name state detail dir t cwd kids home ws surface
  local -A repo_dir
  for r in "$@"; do
    IFS='|' read -r name state detail dir <<< "$r"
    [[ -n $dir ]] && repo_dir+=("$name · $remote_name" "$dir")
  done
  (( $#repo_dir )) || return
  # remote shells, one line each: terminal id|cwd|child processes|$HOME
  local -A shell_cwd shell_kids
  for r in "${(@f)$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote" bash -s <<'EOF' 2>/dev/null
for e in /proc/[0-9]*/environ; do
  p=${e%/environ}; p=${p#/proc/}
  t=$(tr '\0' '\n' <"$e" 2>/dev/null | sed -n 's/^CMUX_TUI_TERMINAL_ID=//p'); [ -n "$t" ] || continue
  pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
  tr '\0' '\n' <"/proc/$pp/environ" 2>/dev/null | grep -qxF "CMUX_TUI_TERMINAL_ID=$t" && continue
  echo "$t|$(readlink "/proc/$p/cwd")|$(pgrep -P "$p" | wc -l | tr -d ' ')|$HOME"
done
EOF
)}"; do
    IFS='|' read -r t cwd kids home <<< "$r"
    [[ -n $t ]] || continue
    shell_cwd[$t]=$cwd; shell_kids[$t]=$kids
  done
  [[ -n $home ]] || return
  # workspace ref -> its terminal ids, and -> description|surface for single-terminal ones
  local -A ws_terms ws_target
  for r in "${(@f)$(cmux ssh-session-list --all-workspaces --json 2>/dev/null \
      | jq -r '.sessions[] | "\(.workspace_ref) \(.session_id)"')}"; do
    [[ -n $r ]] && ws_terms[${r%% *}]+=" ${r#* }"
  done
  for r in "${(@f)$(cmux tree --all --json 2>/dev/null | jq -r '.windows[].workspaces[]
      | [.panes[].surfaces[] | select(.type == "terminal") | .ref] as $s
      | select(($s | length) == 1) | "\(.ref)|\(.description // "")|\($s[0])"')}"; do
    IFS='|' read -r ws detail surface <<< "$r"
    [[ -n ${repo_dir[$detail]} ]] && ws_target[$ws]="$detail|$surface"
  done
  for ws in ${(k)ws_target}; do
    IFS='|' read -r detail surface <<< "${ws_target[$ws]}"
    dir=${repo_dir[$detail]}
    local ok=0
    for t in ${=ws_terms[$ws]}; do
      [[ -n ${shell_cwd[$t]} ]] || continue                 # gone or not ours: ignore
      [[ ${shell_kids[$t]} == 0 && ${shell_cwd[$t]} == $home ]] || { ok=0; break; }
      ok=1
    done
    (( ok )) || continue
    open_cmd "$dir"
    cmux send --workspace "$ws" --surface "$surface" "$REPLY\n" >/dev/null 2>&1 \
      && ws_recd+=("${detail%% · *}")
  done
}

export CMUX_QUIET=1
if (( use_cmux && $+commands[cmux] && $+commands[jq] )) && cmux workspace list --json >/dev/null 2>&1; then
  ensure_ws Local vicks-repos-local "this Mac" local "${local_out[@]}"
  if [[ -n $remote ]]; then
    ensure_ws "${(C)${remote_name%-<->}}" vicks-repos-remote "$remote_name" remote "${remote_out[@]}"
    recd_ws "${remote_out[@]}"
  fi
  zsh "$here/workspaces.zsh" colour      # repo colours for any workspace just added
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
  (( $#ws_recd )) && { print; print "Back in their repo after a reconnect: ${(j:, :)ws_recd}"; }
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
