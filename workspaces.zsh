#!/usr/bin/env zsh
# workspaces.zsh — keep cmux's remote workspaces looking and behaving like the remote
# machine in repos.conf.
#
#   workspaces.zsh adopt <workspace-id>   a new local workspace in the remote group
#                                         becomes a cmux SSH workspace to that machine
#   workspaces.zsh status                 a green "Connected" or red failure pill on
#                                         each remote workspace
#
# `adopt` runs when a terminal starts (vicks.zsh). cmux has no per-group setting for new
# workspaces, so a workspace opened in the remote group starts as a local terminal; this
# opens a real cmux SSH workspace in its place (same name, same group, same spot) and
# closes the local one. The group's own header workspace is never touched.
#
# `status` runs from the banner every few seconds (cmux sends no event when a
# connection changes). It only writes a pill when its value changed, or after cmux
# restarted. cmux's own SSH details stay as they are; the pill adds the colour.
typeset -g here=${0:A:h}
typeset -g REMOTE_GROUP=vicks-repos-remote     # the group's external id, set by repos.zsh
typeset -g PILL=vicks-link

# the "remote" line of repos.conf -> REPLY (an ssh destination), or fail
remote_dest() {
  local line; local -a words
  for line in "${(@f)$(<${VICKS_REPOS_CONF:-$here/repos.conf})}"; do
    words=(${=line%%\#*})
    [[ $words[1] == remote && -n $words[2] ]] && { REPLY=$words[2]; return 0; }
  done
  return 1
}

adopt() {
  local id=$1 dest groups ws group anchor ref title selected new
  [[ -n $id ]] && remote_dest || return 0
  dest=$REPLY
  ws=$(cmux workspace list --json 2>/dev/null | jq -c --arg id "$id" '.workspaces[] | select(.id == $id)') || return 0
  [[ -n $ws ]] || return 0
  [[ $(jq -r '.remote.destination // empty' <<< "$ws") == "" ]] || return 0   # already remote
  ref=$(jq -r .ref <<< "$ws")
  groups=$(cmux workspace-group list --json 2>/dev/null) || return 0
  IFS='|' read -r group anchor <<< "$(jq -r --arg x "$REMOTE_GROUP" --arg r "$ref" '.groups[]
    | select(.external_id == $x and (.member_workspace_refs | index($r)))
    | "\(.ref)|\(.anchor_workspace_ref)"' <<< "$groups")"
  [[ -n $group && $ref != $anchor ]] || return 0

  # one adoption per workspace, even when several of its terminals start together
  local lock="${TMPDIR:-/tmp}/vicks-adopt-$id"
  mkdir "$lock" 2>/dev/null || return 0
  {
    title=$(jq -r 'if .has_custom_title then .custom_title else "" end' <<< "$ws")
    selected=$(jq -r .selected <<< "$ws")
    local -a args=(--no-focus)
    [[ $selected == true ]] && args=(--focus)
    [[ -n $title ]] && args+=(--name "$title")
    new=$(cmux ssh "$dest" $args --json 2>/dev/null | jq -r '.workspace_ref // empty')
    [[ -n $new ]] || return 0
    cmux workspace-group add --group "$group" --workspace "$new" >/dev/null 2>&1
    cmux reorder-workspace --workspace "$new" --after "$ref" >/dev/null 2>&1
    cmux workspace close "$ref" >/dev/null 2>&1
  } always {
    rmdir "$lock" 2>/dev/null
  }
}

status() {
  local cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/vicks
  local f=$cache_dir/ws_link boot r ref state value color icon
  mkdir -p "$cache_dir"
  boot=$(cmux events --snapshot --no-heartbeat 2>/dev/null | jq -r '.boot_id // empty')
  [[ -n $boot ]] || return 0
  local -A had
  if [[ -r $f ]]; then
    local -a lines=("${(@f)$(<$f)}")
    if [[ $lines[1] == "boot $boot" ]]; then
      for r in $lines[2,-1]; do had[${r%%|*}]=${r#*|}; done
    fi
  fi
  local -a now=("boot $boot")
  for r in "${(@f)$(cmux workspace list --json 2>/dev/null | jq -r '.workspaces[]
      | select(.remote.destination != null) | "\(.ref)|\(.remote.state // "unknown")"')}"; do
    IFS='|' read -r ref state <<< "$r"
    [[ -n $ref ]] || continue
    case $state in
      connected)              value=Connected;   color="#34C759"; icon=checkmark.circle.fill ;;
      connecting|reconnecting) value=Connecting;  color="#8E8E93"; icon=arrow.triangle.2.circlepath ;;
      *)                      value=${(C)state}; color="#FF3B30"; icon=exclamationmark.triangle.fill ;;
    esac
    now+=("$ref|$value")
    [[ ${had[$ref]} == $value ]] && continue
    cmux set-status $PILL "$value" --icon $icon --color "$color" --priority 95 \
      --workspace "$ref" >/dev/null 2>&1
  done
  print -rl -- $now > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

export CMUX_QUIET=1
(( $+commands[cmux] && $+commands[jq] )) || exit 0
case $1 in
  adopt)  adopt "$2" ;;
  status) status ;;
  *) print -u2 "usage: workspaces.zsh adopt <workspace-id> | status"; exit 2 ;;
esac
