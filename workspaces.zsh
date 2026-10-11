#!/usr/bin/env zsh
# workspaces.zsh — keep cmux's remote workspaces looking and behaving like the remote
# machine in repos.conf.
#
#   workspaces.zsh new <workspace-id>     a terminal started: adopt, then colour
#   workspaces.zsh adopt <workspace-id>   a new local workspace in the remote group
#                                         becomes a cmux SSH workspace to that machine
#   workspaces.zsh colour                 give every workspace and group its colour
#   workspaces.zsh status                 a green "Connected" or red failure pill on
#                                         each remote workspace
#
# `adopt` runs when a terminal starts (vicks.zsh). cmux has no per-group setting for new
# workspaces, so a workspace opened in the remote group starts as a local terminal; this
# opens a real cmux SSH workspace in its place (same name, same group, same spot) and
# closes the local one. The group's own header workspace is never touched.
#
# `colour`: each repo's workspaces share one colour, on both machines, and no two repos
# on the same machine share one. Group headers carry the machine's colour. Any other
# workspace gets the colour least used in its group, so a new one is coloured as soon as
# its first terminal starts. Red and green stay out: they mean a connection's state. A
# colour you picked yourself (one not on these lists) is kept.
#
# `status` runs from the banner every few seconds (cmux sends no event when a
# connection changes). It only writes a pill when its value changed, or after cmux
# restarted. cmux's own SSH details stay as they are; the pill adds the colour.
typeset -g here=${0:A:h}
typeset -g REMOTE_GROUP=vicks-repos-remote     # external id (prefix) of the remote machine's folders, set by repos.zsh
typeset -g PILL=vicks-link
# bright, far-apart hues: no red or green (connection state), no gold or grey (groups)
typeset -ga REPO_COLORS=("#339AF0" "#FD7E14" "#CC5DE8" "#15AABF" "#F06595" "#7048E8" "#A0785A" "#F8F9FA" "#0B7285")
typeset -gA GROUP_COLORS=(vicks-repos-local "#ADB5BD" vicks-repos-remote "#FAB005")
# colours earlier versions set; still "ours", so they get replaced
typeset -ga OLD_COLORS=("#0E6B8C" "#1565C0" "#7B3F00" "#283593" "#AD1457" "#1A5276" "#A04000" "#6A1B9A" "#006B6B" "#880E4F" "#3E4B5E" "#B8860B")

# the "remote" line of repos.conf -> REPLY (an ssh destination), or fail
remote_dest() {
  local line; local -a words
  for line in "${(@f)$(<${VICKS_REPOS_CONF:-$here/repos.conf})}"; do
    words=(${=line%%\#*})
    [[ $words[1] == remote && -n $words[2] ]] && { REPLY=$words[2]; return 0; }
  done
  return 1
}

# a line per adoption step, so a workspace that did not turn into SSH can be explained
log() { print -r -- "$(date '+%F %T') $*" >> ${XDG_CACHE_HOME:-$HOME/.cache}/vicks/adopt.log; }

adopt() {
  local id=$1 dest groups ws group anchor ref title selected new
  mkdir -p ${XDG_CACHE_HOME:-$HOME/.cache}/vicks; log "adopt $id: start"
  [[ -n $id ]] && remote_dest || return 0
  dest=$REPLY
  ws=$(cmux workspace list --json 2>/dev/null | jq -c --arg id "$id" '.workspaces[] | select(.id == $id)') || return 0
  [[ -n $ws ]] || { log "adopt $id: not in this window's workspace list"; return 0; }
  [[ $(jq -r '.remote.destination // empty' <<< "$ws") == "" ]] || { log "adopt $id: already remote"; return 0; }
  ref=$(jq -r .ref <<< "$ws")
  groups=$(cmux workspace-group list --json 2>/dev/null) || return 0
  IFS='|' read -r group anchor <<< "$(jq -r --arg x "$REMOTE_GROUP" --arg r "$ref" '.groups[]
    | select((.external_id // "" | startswith($x)) and (.member_workspace_refs | index($r)))
    | "\(.ref)|\(.anchor_workspace_ref)"' <<< "$groups")"
  [[ -n $group && $ref != $anchor ]] || { log "adopt $id: $ref not in the remote group (or its header)"; return 0; }
  # only a fresh workspace: its one terminal is the one starting now. Closing it needs
  # --force (that terminal runs the cockpit), which must never hit work in progress.
  local surfaces=$(cmux tree --all --json 2>/dev/null | jq --arg r "$ref" \
    '[.windows[].workspaces[] | select(.ref == $r) | .panes[].surfaces[]] | length')
  [[ $surfaces == 1 ]] || { log "adopt $id: $ref has $surfaces surfaces, not a fresh workspace"; return 0; }

  # one adoption per workspace, even when several of its terminals start together
  local lock="${TMPDIR:-/tmp}/vicks-adopt-$id"
  mkdir "$lock" 2>/dev/null || return 0
  {
    title=$(jq -r 'if .has_custom_title then .custom_title else "" end' <<< "$ws")
    selected=$(jq -r .selected <<< "$ws")
    # --focus cannot be combined with --json, so focus follows separately
    local -a args=(--no-focus)
    [[ -n $title ]] && args+=(--name "$title")
    local out; out=$(cmux ssh "$dest" $args --json 2>&1)
    new=$(jq -r '.workspace_ref // empty' <<< "$out" 2>/dev/null)
    [[ -n $new ]] || { log "adopt $id: cmux ssh $dest $args failed: ${out//$'\n'/ }"; return 0; }
    cmux workspace-group add --group "$group" --workspace "$new" >/dev/null 2>&1
    cmux reorder-workspace --workspace "$new" --after "$ref" >/dev/null 2>&1
    [[ $selected == true ]] && cmux workspace select "$new" >/dev/null 2>&1
    cmux workspace close "$ref" --force >/dev/null 2>&1
    log "adopt $id: $ref replaced by $new"
  } always {
    rmdir "$lock" 2>/dev/null
  }
}

colour() {
  local conf=${VICKS_REPOS_CONF:-$here/repos.conf} line repo name w remote_name="" i c r
  local -a words ours=(${(U)REPO_COLORS} ${(U)GROUP_COLORS} ${(U)OLD_COLORS})
  local -a repos; local -A machines           # repo name -> " local remote"
  for line in "${(@f)$(<$conf)}"; do
    words=(${=line%%\#*}); (( $#words )) || continue
    if [[ $words[1] == remote ]]; then remote_name=${${words[2]#*@}%%.*}; continue; fi
    name=${words[1]##*/}; repos+=($name)
    for w in $words[2,-1]; do [[ $w == (local|remote) ]] && machines[$name]+=" $w"; done
  done

  # a repo takes the first colour no repo on any of its machines has yet
  local -A repo_colour used        # used: "machine:colour" -> 1
  for name in $repos; do
    for c in $REPO_COLORS; do
      for w in ${=machines[$name]}; do (( ${+used[$w:$c]} )) && continue 2; done
      break
    done
    (( ${+used[${${=machines[$name]}[1]}:$c]} )) && c=$REPO_COLORS[$(( ($#repo_colour % $#REPO_COLORS) + 1 ))]
    repo_colour[$name]=$c
    for w in ${=machines[$name]}; do used[$w:$c]=1; done
  done
  local -A want
  for name in $repos; do
    for w in ${=machines[$name]}; do
      case $w in
        local)  want+=("$name · this Mac" $repo_colour[$name]) ;;
        remote) [[ -n $remote_name ]] && want+=("$name · $remote_name" $repo_colour[$name]) ;;
      esac
    done
  done

  local groups ws ref desc cur gid
  groups=$(cmux workspace-group list --json 2>/dev/null) || return 0
  ws=$(cmux workspace list --json 2>/dev/null) || return 0
  # group headers
  for r in "${(@f)$(jq -r '.groups[] | "\(.ref)|\(.external_id // "")|\(.custom_color // "")"' <<< "$groups")}"; do
    IFS='|' read -r ref gid cur <<< "$r"
    c=${GROUP_COLORS[$gid]}
    [[ -z $c && $gid == $REMOTE_GROUP-* ]] && c=${GROUP_COLORS[$REMOTE_GROUP]}   # project folders
    [[ -n $c && ${(U)cur} != ${(U)c} ]] && [[ -z $cur || -n ${ours[(r)${(U)cur}]} ]] || continue
    cmux workspace-group set-color "$ref" --hex "$c" >/dev/null 2>&1
  done
  # workspaces: ref|description|colour|group ref ("" for none)|is a group header
  local -a rows=("${(@f)$(jq -r --argjson g "$groups" '.workspaces[] | .ref as $r
    | ([$g.groups[] | select(.member_workspace_refs | index($r))][0]) as $grp
    | "\($r)|\(.description // "")|\(.custom_color // "")|\($grp.ref // "")|\(($grp.anchor_workspace_ref // "") == $r)"' <<< "$ws")}")
  local grp anchor
  local -A count                    # "group:colour" -> workspaces using it
  for r in $rows; do                # repo workspaces first, so the others fit around them
    IFS='|' read -r ref desc cur grp anchor <<< "$r"
    c=${want[$desc]}
    if [[ -n $c && ${(U)cur} != ${(U)c} ]] && [[ -z $cur || -n ${ours[(r)${(U)cur}]} ]]; then
      cmux workspace-action --workspace "$ref" --action set-color --color "$c" >/dev/null 2>&1; cur=$c
    fi
    [[ -n $cur ]] && count[$grp:${(U)cur}]=$(( ${count[$grp:${(U)cur}]:-0} + 1 ))
  done
  for r in $rows; do                # then any uncoloured workspace, group headers aside
    IFS='|' read -r ref desc cur grp anchor <<< "$r"
    [[ -z $cur && -z ${want[$desc]} && $anchor != true ]] || continue
    local best="" n min=999999
    for c in $REPO_COLORS; do
      n=${count[$grp:${(U)c}]:-0}; (( n < min )) && { min=$n; best=$c; }
    done
    cmux workspace-action --workspace "$ref" --action set-color --color "$best" >/dev/null 2>&1
    count[$grp:${(U)best}]=$(( ${count[$grp:${(U)best}]:-0} + 1 ))
  done
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
  new)    adopt "$2"; colour ;;
  adopt)  adopt "$2" ;;
  colour) colour ;;
  status) status ;;
  *) print -u2 "usage: workspaces.zsh new|adopt <workspace-id> | colour | status"; exit 2 ;;
esac
