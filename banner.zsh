#!/usr/bin/env zsh
# banner.zsh — X-wing welcome banner with machine metadata and a route to the internet.
#
# Usage:  banner.zsh            one-shot banner (what a new terminal shows)
#         banner.zsh --fresh    ignore every cache and look everything up again
#         banner.zsh --no-net   skip public IP lookup, traceroute and speed tests
#         banner.zsh --new-window   also start the once-per-window speed tests in the background
#         banner.zsh --speedtest    run the speed tests now and print the results
#         banner.zsh --dash     live dashboard that redraws in place (used by `cockpit`)
#                               keys: r = refresh everything now, q = quit
#           --side              dashboard is in a narrow side pane (single column)
#           --once              print one dashboard frame and exit
#           --cols N            assume a terminal N columns wide
#
# Env:    VICKS_ART=/path/to/file    alternative art (tokens: {W} {G} {D} {R} {O} {C} {B} {Y} {X})
#         VICKS_CACHE_TTL=600        seconds to cache public IP + traceroute for the banner
#         VICKS_DASH_NET_TTL=120     the same, for the live dashboard
#         VICKS_DASH_INTERVAL=5      seconds between dashboard redraws
#         VICKS_DASH_ART=1           0 = never draw the art in the dashboard
#         VICKS_DASH_ART_FILE=path   art for the dashboard (default: xwing-small.art)
#         VICKS_REMOTE_ART=tie       art when reached over SSH: tie, deathstar, xwing or a file path
#         VICKS_UPDATE_TTL=21600     seconds between macOS / Homebrew update checks
#         VICKS_TRACE_TARGET=8.8.8.8  where the traceroute is aimed
#         VICKS_TRACE_STOP=owner     where the shown route ends: owner (first hop in the target's
#                                    own network, Google for 8.8.8.8), public (first public address), full
#         VICKS_TOP_N=5              how many apps the TOP APPS lists show
#         VICKS_SPEEDTEST=0          never run speed tests (1 = also run them on remote machines)
#         VICKS_SPEEDTEST_SECONDS=8  time cap for each direction of the internet test
#         VICKS_SPEEDTEST_MIN_AGE=300  reuse a result younger than this instead of retesting
#         VICKS_IPERF_HOST=user@host   Tailscale peer for the iperf3 test (none = no test)
#         VICKS_TIPS=0               hide the rotating tips
#         VICKS_TIPS_SECONDS=30      how long each page of tips stays up
#         VICKS_TIPS_COUNT=5         tips per page
#         VICKS_TIPS_FILE=path       your own tips file ("key | description" lines)
#       These can also live in ~/.config/vicks/config as plain VAR=value lines.

emulate -L zsh
setopt extendedglob no_nomatch pipe_fail
zmodload zsh/datetime 2>/dev/null
zmodload -F zsh/stat b:zstat 2>/dev/null   # only zstat, keep the system `stat`

# ---------------------------------------------------------------- colours ---
# 256-colour codes work in Terminal.app, iTerm2, Warp, VS Code, Ghostty, tmux.
# Star Wars yellow is #FFE81F; use truecolor when the terminal advertises it.
local C_RESET=$'\e[0m' C_BOLD=$'\e[1m'
local C_W=$'\e[38;5;255m'   # hull white
local C_G=$'\e[38;5;250m'   # hull grey
local C_D=$'\e[38;5;244m'   # dark grey
local C_R=$'\e[38;5;196m'   # red stripes (Red Squadron)
local C_O=$'\e[38;5;208m'   # engine glow (orange)
local C_C=$'\e[38;5;117m'   # canopy blue
local C_S=$'\e[38;5;110m'   # TIE hull steel blue
local C_L=$'\e[38;5;46m'    # Imperial laser green
local C_B=$'\e[38;5;255m'   # canopy frame white
local C_Y
if [[ ${COLORTERM:-} == (truecolor|24bit) ]]; then
  C_Y=$'\e[38;2;255;232;31m'
else
  C_Y=$'\e[38;5;220m'
fi
local C_K=$'\e[38;5;245m'   # keys
local C_V=$'\e[38;5;252m'   # values
local C_OK=$'\e[38;5;82m' C_WARN=$'\e[38;5;214m' C_BAD=$'\e[38;5;196m' C_INFO=$'\e[38;5;75m'

# ---------------------------------------------------------------- options ---
local fresh=0 nonet=0 dash=0 once=0 side=0 force_cols=0 new_window=0 speed_now=0
while (( $# )); do
  case $1 in
    --fresh)  fresh=1 ;;
    --no-net) nonet=1 ;;
    --dash)   dash=1 ;;
    --once)   once=1 ;;
    --side)   side=1 ;;
    --new-window) new_window=1 ;;   # a terminal window just opened: run the once-per-window speed tests
    --speedtest)  speed_now=1 ;;    # run the speed tests now and print the results
    --cols)   force_cols=$2; shift ;;
  esac
  shift
done
local compact=$dash   # dashboard uses shorter lines
local bar_w=20; (( compact )) && bar_w=14   # usage bar width
local async=$dash     # dashboard never blocks on a lookup

local here=${0:A:h}
# A shell reached over SSH is a remote machine: it flies Imperial colours, so one
# glance tells you which machine a window is on.
local is_remote=0
[[ -n ${SSH_CONNECTION:-}${SSH_TTY:-}${VICKS_REMOTE:-} ]] && is_remote=1
local art=${VICKS_ART:-$here/xwing.art}
if (( is_remote )); then
  case ${VICKS_REMOTE_ART:-tie} in
    tie)       art=$here/tie.art ;;
    deathstar) art=$here/deathstar.art ;;
    xwing)     (( dash )) && art=$here/xwing-small.art ;;
    *)         art=$VICKS_REMOTE_ART ;;             # a path to your own file
  esac
elif (( dash )); then
  # the pinned dashboard uses the smaller X-wing so the data gets more room
  art=${VICKS_DASH_ART_FILE:-$here/xwing-small.art}
fi
[[ -r $art ]] || art=$here/xwing.art
local ttl=${VICKS_CACHE_TTL:-600}
(( dash )) && ttl=${VICKS_DASH_NET_TTL:-120}
local upd_ttl=${VICKS_UPDATE_TTL:-21600}
local target=${VICKS_TRACE_TARGET:-8.8.8.8}
# Where the displayed route stops:
#   owner  = first hop inside the target's own network (Google for 8.8.8.8)
#   public = first public address
#   full   = every hop to the target
local trace_stop=${VICKS_TRACE_STOP:-owner}
(( ${VICKS_TRACE_FULL:-0} )) && trace_stop=full
local cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/vicks
mkdir -p "$cache_dir" 2>/dev/null

local is_mac=0
[[ $OSTYPE == darwin* ]] && is_mac=1

# Optional settings file, read by every banner and dashboard: plain VAR=value lines,
# for example VICKS_IPERF_HOST=dev@devbox-1
[[ -r ${XDG_CONFIG_HOME:-$HOME/.config}/vicks/config ]] && source "${XDG_CONFIG_HOME:-$HOME/.config}/vicks/config"

# ---------------------------------------------------------------- helpers ---
# kv "label" "value"  -> aligned key/value line
kv() { printf "  %s%-12s%s %s%s%s\n" "$C_K" "$1" "$C_RESET" "$C_V" "$2" "$C_RESET"; }
# rep <char> <n>  -> char repeated n times (byte-safe in any locale)
rep() { local s=""; repeat ${2:-0} s+=$1; print -rn -- "$s"; }
# section "title" ["dim suffix"]
section() {
  local n=$(( 46 - ${#1} - ${#2} )); (( n < 3 )) && n=3
  printf "%s%s%s%s %s%s%s%s%s\n" "$C_Y" "$C_BOLD" "$1" "$C_RESET" "$C_D" "${2:+$2 }" "$(rep ─ $n)" "$C_RESET"
}
# bar <pct> [width]  -> coloured usage bar
bar() {
  local pct=${1%.*} width=${2:-$bar_w}; (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  local filled=$(( pct * width / 100 )) col=$C_OK
  (( pct >= 70 )) && col=$C_WARN
  (( pct >= 90 )) && col=$C_BAD
  printf "%s%s%s%s%s %3d%%" "$col" "$(rep █ $filled)" "$C_D" "$(rep ░ $((width - filled)))" "$C_RESET" "$pct"
}
# mtime <file>  -> REPLY = modification time, 0 if missing
mtime() { local -a st; if zstat -A st +mtime -- "$1" 2>/dev/null; then REPLY=$st[1]; else REPLY=0; fi; }
# ago <seconds>  -> REPLY = "5m ago"
ago() {
  local s=$1
  if   (( s < 90 ));     then REPLY="just now"
  elif (( s < 5400 ));   then REPLY="$(( s / 60 ))m ago"
  elif (( s < 172800 )); then REPLY="$(( s / 3600 ))h ago"
  else                        REPLY="$(( s / 86400 ))d ago"
  fi
}
# cached [-a] <name> <ttl> <cmd...>  -> stdout of cmd, cached for ttl seconds.
#   -a   slow command (update checks): never wait for it. Print the last known
#        value and refresh in the background when stale or when --fresh is given.
#   The dashboard treats every lookup that way, except right after pressing r.
cached() {
  local allow_async=0
  [[ $1 == -a ]] && { allow_async=1; shift; }
  local name=$1 cttl=$2; shift 2
  local f=$cache_dir/$name
  mtime "$f"
  if (( fresh || EPOCHSECONDS - REPLY >= cttl )); then
    if (( allow_async || (async && ! fresh) )); then
      mtime "$f.lock"
      if (( EPOCHSECONDS - REPLY > 120 )); then
        : > "$f.lock"
        ( "$@" > "$f.tmp" 2>/dev/null; mv -f "$f.tmp" "$f"; rm -f "$f.lock" ) >/dev/null 2>&1 </dev/null &!
      fi
    else
      "$@" > "$f.tmp" 2>/dev/null; mv -f "$f.tmp" "$f"
    fi
  fi
  [[ -f $f ]] && cat "$f"
}
# classify an IPv4 address
ipclass() {
  case $1 in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) echo private ;;
    100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) echo cgnat ;;
    169.254.*) echo link-local ;;
    127.*) echo loopback ;;
    *) echo public ;;
  esac
}
# vlen <string>  -> REPLY = visible length (colour codes not counted)
vlen() { local s=${1//$'\e'\[[0-9;]#m/}; REPLY=${#s}; }
# vtrunc <string> <max>  -> REPLY = string cut to max visible characters
vtrunc() {
  local s=$1 max=$2 out="" n=0 esc
  while [[ -n $s ]]; do
    if [[ $s == $'\e'\[[0-9\;]#m* ]]; then
      esc=${(M)s#$'\e'\[[0-9;]#m}; out+=$esc; s=${s#$esc}
    else
      (( n >= max - 1 )) && { out+="…"; break; }
      out+=$s[1]; s=$s[2,-1]; (( n++ ))
    fi
  done
  REPLY=$out$C_RESET
}

# ---------------------------------------------------------- speed tests ---
# Run once per new terminal window, in the background, never on a redraw.
#   internet:  parallel downloads and uploads against speed.cloudflare.com, each
#              capped at VICKS_SPEEDTEST_SECONDS so a slow link is not tied up for minutes
#   tailscale: iperf3 to VICKS_IPERF_HOST (user@host). A one-shot iperf3 server is
#              started there over SSH for each direction, so nothing stays running.
# Results land in the cache as "OK <down> <up> [peer]" or "ERR <reason>".
run_speed_inet() {
  local secs=${VICKS_SPEEDTEST_SECONDS:-8} down up upf=$cache_dir/up.$$.bin
  down=$(curl -s -Z -m $secs -o /dev/null -w '%{speed_download} %{http_code}\n' \
           'https://speed.cloudflare.com/__down?bytes=90000000&n=[1-8]' 2>/dev/null \
         | awk '$2 == 200 {s += $1} END {printf "%.0f", s * 8 / 1000000}')
  head -c 50000000 /dev/zero > "$upf"
  up=$(curl -s -Z -m $secs -o /dev/null -w '%{speed_upload} %{http_code}\n' --data-binary @"$upf" \
         'https://speed.cloudflare.com/__up?n=[1-4]' 2>/dev/null \
       | awk '$2 < 400 {s += $1} END {printf "%.0f", s * 8 / 1000000}')
  rm -f "$upf"
  if (( ${down:-0} == 0 && ${up:-0} == 0 )); then print "ERR speed test failed (offline or blocked)"
  else print "OK ${down:-0} ${up:-0}"; fi
}
run_speed_ts() {
  local host=${VICKS_IPERF_HOST:-} port=${VICKS_IPERF_PORT:-5201} secs=${VICKS_IPERF_SECONDS:-5}
  local peer=${host#*@} target rc up down
  (( $+commands[iperf3] )) || { print "ERR iperf3 is not installed on this machine"; return; }
  (( $+commands[jq] ))     || { print "ERR jq is not installed on this machine"; return; }
  target=$(command ssh -G "$host" 2>/dev/null | awk '$1 == "hostname" {print $2; exit}'); : ${target:=$peer}
  # one-shot server on the peer: serves a single test, and gives up after 30s if none arrives
  start_server() {
    command ssh -o BatchMode=yes -o ConnectTimeout=6 "$host" \
      "command -v iperf3 >/dev/null 2>&1 || exit 42
       if command -v timeout >/dev/null 2>&1; then nohup timeout 30 iperf3 -s -1 -p $port >/dev/null 2>&1 </dev/null &
       else nohup iperf3 -s -1 -p $port >/dev/null 2>&1 </dev/null & fi" </dev/null >/dev/null 2>&1
  }
  mbps() { jq -r '.end.sum_received.bits_per_second // 0' 2>/dev/null | awk '{printf "%.0f", $1 / 1000000}'; }
  start_server; rc=$?
  if (( rc == 42 )); then print "ERR iperf3 is not installed on $peer"; return; fi
  if (( rc != 0 )); then print "ERR cannot reach $peer over SSH"; return; fi
  sleep 1
  up=$(iperf3 -c "$target" -p $port -t $secs -J 2>/dev/null | mbps)
  start_server; sleep 1
  down=$(iperf3 -c "$target" -p $port -t $secs -R -J 2>/dev/null | mbps)
  if (( ${down:-0} == 0 && ${up:-0} == 0 )); then print "ERR iperf3 test to $peer failed"
  else print "OK ${down:-0} ${up:-0} $peer"; fi
}
# which tests apply here: remote machines only test when asked to (VICKS_SPEEDTEST=1)
speed_tests() {
  reply=()
  (( nonet )) && return
  local on=${VICKS_SPEEDTEST:-}
  [[ -z $on ]] && { (( is_remote )) && on=0 || on=1; }
  [[ $on == 0 ]] && return
  reply=(inet)
  [[ -n ${VICKS_IPERF_HOST:-} ]] && reply+=(ts)
}
# speedtests_start <force> -> run the tests one after the other in the background.
# Skipped when a test is already running, or when the last result is younger than
# VICKS_SPEEDTEST_MIN_AGE seconds (so opening several windows in a row tests once).
speedtests_start() {
  local force=$1 min_age=${VICKS_SPEEDTEST_MIN_AGE:-300} name f
  local -a todo
  speed_tests
  for name in $reply; do
    f=$cache_dir/speed_$name
    mtime "$f.lock"; (( EPOCHSECONDS - REPLY < 180 )) && continue
    if (( ! force )); then mtime "$f"; (( EPOCHSECONDS - REPLY < min_age )) && continue; fi
    : > "$f.lock"; todo+=($name)
  done
  (( $#todo )) || return 0
  ( for name in $todo; do
      f=$cache_dir/speed_$name
      run_speed_$name > "$f.tmp" 2>/dev/null; mv -f "$f.tmp" "$f"; rm -f "$f.lock"
    done ) >/dev/null 2>&1 </dev/null &!
}
# speed_line <inet|ts> -> the value for a "Speed" row, or nothing when there is nothing to say
speed_line() {
  local f=$cache_dir/speed_$1 running=0 res="" when
  mtime "$f.lock"; (( EPOCHSECONDS - REPLY < 180 )) && running=1
  [[ -s $f ]] && res="$(<$f)"
  if [[ -z $res ]]; then (( running )) && print -r -- "${C_D}testing…"; return; fi
  mtime "$f"; ago $(( EPOCHSECONDS - REPLY )); when=$REPLY
  (( running )) && when="retesting…"
  local -a parts=(${=res})
  if [[ $parts[1] == OK ]]; then
    print -r -- "${C_OK}↓ ${parts[2]} Mbps  ${C_INFO}↑ ${parts[3]} Mbps${C_D}${parts[4]:+ · iperf3 to ${parts[4]}} · ${when}"
  else
    print -r -- "${C_WARN}${res#ERR }${C_D} · ${when}"
  fi
}

# ------------------------------------------------------ static facts ---
local os kernel model chip cpus mem_total computer_name=""
kernel="$(uname -s) $(uname -r) ($(uname -m))"
if (( is_mac )); then
  os="macOS $(sw_vers -productVersion) build $(sw_vers -buildVersion)"
  model="$(sysctl -n hw.model 2>/dev/null)"
  chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  cpus=$(sysctl -n hw.ncpu 2>/dev/null)
  mem_total=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
  computer_name="$(scutil --get ComputerName 2>/dev/null)"
else
  os="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"
  model="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)"
  chip="$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  cpus=$(nproc 2>/dev/null)
  mem_total=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
fi

# ------------------------------------------------------ update checks ---
# Both are slow (seconds), so they run in the background and are cached for hours.
check_macos_updates() {
  local out; out="$(softwareupdate -l 2>&1)"
  if [[ $out == *Title:* ]]; then
    print -r -- "$out" | sed -nE 's/^[[:space:]]*Title: (.*), Version: ([^,]*),.*/\1|\2/p'
  elif [[ $out == *"No new software"* ]]; then
    print OK
  else
    print ERR
  fi
}
# Linux (apt): counts packages apt already knows are upgradable; no sudo, no network.
check_linux_updates() {
  (( $+commands[apt] )) || { print NA; return; }
  print -r -- "N|$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable')"
  [[ -f /var/run/reboot-required ]] && print REBOOT
  return 0
}
upd_linux() {
  local res; res="$(cached -a linux_updates $upd_ttl check_linux_updates)"
  if [[ -z $res ]]; then print -r -- "${C_D}checking…"; return; fi
  [[ $res == NA* ]] && return
  local n=${${(f)res}[1]#N|} s
  if (( n > 0 )); then s="${C_WARN}⬆ ${n} package(s) upgradable"; else s="${C_OK}✓ packages up to date"; fi
  [[ $res == *REBOOT* ]] && s+="${C_D} · ${C_BAD}reboot required"
  print -r -- "$s"
}
check_brew() {
  local v; v="$(brew --version 2>/dev/null | head -1)"
  [[ -z $v ]] && { print ERR; return; }
  print -r -- "V|${v#Homebrew }"
  brew outdated --quiet 2>/dev/null
}
# upd_macos -> line 1: status; line 2 (optional): names of the other pending updates
upd_macos() {
  local res; res="$(cached -a macos_updates $upd_ttl check_macos_updates)"
  if [[ -z $res ]]; then print -r -- "${C_D}checking…"; return; fi
  mtime "$cache_dir/macos_updates"; ago $(( EPOCHSECONDS - REPLY )); local when=$REPLY
  case $res in
    OK)  print -r -- "${C_OK}✓ macOS and Apple software up to date ${C_D}(checked $when)" ;;
    ERR) print -r -- "${C_D}could not check (offline?)" ;;
    *)
      local -a os_upd other; local e t v
      for e in "${(@f)res}"; do
        t=${e%%|*}; v=${e##*|}
        [[ $t == *"$v"* ]] || t="$t $v"
        if [[ $t == macOS* ]]; then os_upd+=("$t"); else other+=("$t"); fi
      done
      local s
      if (( compact )); then
        # short form for the dashboard
        if (( $#os_upd )); then s="${C_WARN}⬆ ${(j:, :)os_upd}"; else s="${C_OK}✓ macOS current"; fi
        (( $#other )) && s+="${C_D} · +${#other} Apple"
        print -r -- "$s"
        return
      fi
      if (( $#os_upd )); then s="${C_WARN}⬆ ${(j:, :)os_upd} available"
      else s="${C_OK}✓ macOS up to date"; fi
      (( $#other )) && s+="${C_D} · ${C_WARN}${#other} other Apple update(s)"
      print -r -- "$s ${C_D}(checked $when)"
      if (( $#other > 3 )); then print -r -- "${C_D}${(j:, :)other[1,3]} and $(( $#other - 3 )) more"
      elif (( $#other )); then print -r -- "${C_D}${(j:, :)other}"; fi
      ;;
  esac
}
upd_brew() {
  local res; res="$(cached -a brew_outdated $upd_ttl check_brew)"
  if [[ -z $res ]]; then print -r -- "${C_D}checking…"; return; fi
  [[ $res == ERR ]] && { print -r -- "${C_D}could not check"; return; }
  mtime "$cache_dir/brew_outdated"; ago $(( EPOCHSECONDS - REPLY )); local when=$REPLY
  local -a lines=("${(@f)res}")
  local ver=${lines[1]#V|}; shift lines
  if (( $#lines == 0 )); then
    print -r -- "${ver} ${C_OK}✓ all packages up to date ${C_D}(checked $when)"
  else
    local names="${(j:, :)lines[1,4]}"; (( $#lines > 4 )) && names+=" and $(( $#lines - 4 )) more"
    print -r -- "${ver} ${C_WARN}⬆ ${#lines} outdated${C_D}: ${names} · run ${C_V}brew upgrade"
  fi
}

# ------------------------------------------------------------- blocks ---
# Every block prints plain lines; the caller stacks them (banner) or
# arranges them in columns (dashboard).

blk_art() {
  local indent="    "; (( compact )) && indent=""
  if [[ -r $art ]]; then
    local line
    while IFS= read -r line; do
      line=${line//\{W\}/$C_W}; line=${line//\{G\}/$C_G}; line=${line//\{D\}/$C_D}
      line=${line//\{R\}/$C_R}; line=${line//\{O\}/$C_O}; line=${line//\{C\}/$C_C}
      line=${line//\{B\}/$C_B}; line=${line//\{Y\}/$C_Y}; line=${line//\{X\}/$C_RESET}
      line=${line//\{S\}/$C_S}; line=${line//\{L\}/$C_L}
      print -r -- "$indent$line$C_RESET"
    done < "$art"
  fi
  if (( compact )); then
    # kept short so the caption is never wider than the art above it
    print -r -- "${C_Y}${C_BOLD}May the Force be with you.${C_RESET}"
    (( is_remote )) && print -r -- "${C_WARN}Remote: $(hostname -s)${C_RESET}"
  else
    print
    if (( is_remote )); then
      print -r -- "  ${C_Y}${C_BOLD}May the Force be with you, ${USER}.${C_RESET}  ${C_WARN}Remote machine $(hostname -s), reached over SSH${C_RESET}"
    else
      print -r -- "  ${C_Y}${C_BOLD}May the Force be with you, ${USER}.${C_RESET}  ${C_D}Red Five standing by on $(hostname -s)${C_RESET}"
    fi
  fi
}

blk_system() {
  section "SYSTEM"
  if (( compact )); then kv "Host" "$(hostname -s)"
  else kv "Host" "$(hostname -s) ${C_D}($(hostname))"; fi
  (( is_mac && ! compact )) && kv "Name" "$computer_name"
  kv "OS" "$os"
  if (( is_mac )); then
    local -a u=("${(@f)$(upd_macos)}")
    kv "OS updates" "$u[1]"
    (( $#u > 1 && ! compact )) && kv "" "$u[2]"
  else
    local lu; lu="$(upd_linux)"
    [[ -n $lu ]] && kv "OS updates" "$lu"
  fi
  kv "Kernel" "$kernel"
  if (( compact )); then kv "Hardware" "${chip:-?} · ${cpus} cores · ${mem_total} GB · ${model:-?}"
  else kv "Hardware" "${model:-?} · ${chip:-?} · ${cpus} cores · ${mem_total} GB RAM"; fi
  (( $+commands[brew] )) && kv "Homebrew" "$(upd_brew)"
  if (( compact )); then
    kv "Date" "$(date '+%a %d %b %Y, %H:%M:%S %Z')"
  else
    kv "Shell" "zsh $ZSH_VERSION · ${TERM_PROGRAM:-${TERM:-unknown terminal}}"
    kv "Date" "$(date '+%A %d %B %Y, %H:%M %Z')"
  fi
  kv "Uptime" "$(uptime | sed -E 's/.* up +//; s/, +[0-9]+ users?.*//; s/  +/ /g')"
  if (( compact )); then
    # one line: every logged-in user with their session count
    local -A sessions; local u2 s=""
    while read -r u2 _; do [[ -n $u2 ]] && (( sessions[$u2]++ )); done <<< "$(who 2>/dev/null)"
    for u2 in ${(ko)sessions}; do
      if [[ $u2 == $USER ]]; then s+="${C_V}${u2} ×${sessions[$u2]}  "
      else s+="${C_WARN}${u2} ×${sessions[$u2]} (someone else)  "; fi
    done
    kv "Logged in" "$s"
  fi
}

blk_who() {
  section "WHO IS HERE"
  local me=$USER who_out u tag
  who_out="$(who 2>/dev/null)"
  local -A sessions
  while read -r u _; do [[ -n $u ]] && (( sessions[$u]++ )); done <<< "$who_out"
  for u in ${(ko)sessions}; do
    if [[ $u == $me ]]; then tag="${C_D}(you)"; else tag="${C_WARN}← someone else"; fi
    kv "$u" "${sessions[$u]} session(s) $tag"
  done
  local remote; remote="$(print -r -- "$who_out" | awk '$NF ~ /^\(/ {print $1, $NF}' | sort -u)"
  [[ -n $remote ]] && kv "Remote" "$(print -r -- "$remote" | tr '\n' ' ')"
  [[ -n ${SSH_CONNECTION:-} ]] && kv "You via SSH" "${SSH_CONNECTION%% *} → ${SSH_CONNECTION##* }"
  kv "Last login" "$(last -1 "$me" 2>/dev/null | awk 'NR==1{$1=""; print}' | sed 's/^ *//')"
}

# proc_snapshot: one ps call per frame -> cpu_total, top_cpu, top_mem.
# Processes are grouped by program name, so an app's helpers count as one entry.
# CPU is a share of the whole machine, the same scale as the CPU bar.
local cpu_total=0
local -a top_cpu top_mem
proc_snapshot() {
  local psout line
  if (( is_mac )); then psout="$(ps -A -c -o pcpu=,rss=,comm= 2>/dev/null)"
  else psout="$(ps -eo pcpu=,rss=,comm= 2>/dev/null)"; fi
  top_cpu=(); top_mem=()
  for line in "${(@f)$(print -r -- "$psout" | awk -v n="${cpus:-1}" -v k=${VICKS_TOP_N:-5} '
    {
      c = $1; r = $2; $1 = ""; $2 = ""; sub(/^ +/, "")
      # fold helpers into their app: "Claude Helper (Renderer)" -> "Claude"
      sub(/ Helper.*$/, ""); sub(/^com\.apple\./, "")
      if ($0 ~ /^WebKit\./) $0 = "WebKit web pages"
      total += c; cpu[$0] += c; mem[$0] += r
    }
    END {
      printf "T|%d\n", total / n
      for (i = 1; i <= k; i++) {
        best = ""; for (p in cpu) if (best == "" || cpu[p] > cpu[best]) best = p
        if (best == "") break
        printf "C|%s|%.1f%%\n", best, cpu[best] / n; delete cpu[best]
      }
      for (i = 1; i <= k; i++) {
        best = ""; for (p in mem) if (best == "" || mem[p] > mem[best]) best = p
        if (best == "") break
        g = mem[best] / 1048576
        if (g >= 1) printf "M|%s|%.1fG\n", best, g; else printf "M|%s|%.0fM\n", best, mem[best] / 1024
        delete mem[best]
      }
    }')}"; do
    case $line in
      T\|*) cpu_total=${line#T|} ;;
      C\|*) top_cpu+=("${line#C|}") ;;
      M\|*) top_mem+=("${line#M|}") ;;
    esac
  done
}

# The biggest consumers, two lists side by side: by CPU and by memory.
blk_top() {
  section "TOP APPS"
  local nw=24; (( compact )) && nw=17
  printf "  %s%-${nw}s %6s   %-${nw}s %6s%s\n" "$C_K" "by CPU" "" "by memory" "" "$C_RESET"
  local i cn cv mn mv ccol
  for (( i = 1; i <= ${#top_cpu} || i <= ${#top_mem}; i++ )); do
    cn=${top_cpu[i]%|*}; cv=${top_cpu[i]##*|}
    mn=${top_mem[i]%|*}; mv=${top_mem[i]##*|}
    (( ${#cn} > nw )) && cn="${cn[1,nw-1]}…"
    (( ${#mn} > nw )) && mn="${mn[1,nw-1]}…"
    ccol=$C_V; (( ${cv%%.*} >= 20 )) && ccol=$C_WARN; (( ${cv%%.*} >= 50 )) && ccol=$C_BAD
    printf "  %s%-${nw}s %s%6s   %s%-${nw}s %s%6s%s\n" \
      "$C_V" "$cn" "$ccol" "$cv" "$C_V" "$mn" "$C_INFO" "$mv" "$C_RESET"
  done
}

blk_resources() {
  section "RESOURCES"
  local load cpu_pct mem_used_pct
  load="$(uptime | sed -E 's/.*load averages?: //')"
  cpu_pct=$cpu_total
  kv "CPU" "$(bar $cpu_pct)  ${C_D}load $load"
  if (( is_mac )); then
    local pg active=0 wired=0 compressed=0
    pg=$(sysctl -n hw.pagesize)
    eval "$(vm_stat | awk -F'[: .]+' '
      /Pages active/           {print "active="$3}
      /Pages wired/            {print "wired="$4}
      /occupied by compressor/ {print "compressed="$5}')"
    local used_gb=$(( (active + wired + compressed) * pg / 1024 / 1024 / 1024 ))
    mem_used_pct=$(( used_gb * 100 / mem_total ))
    local note="${used_gb}/${mem_total} GB"; (( compact )) || note+=" (active+wired+compressed)"
    kv "Memory" "$(bar $mem_used_pct)  ${C_D}${note}"
  else
    local mt=1 mu=0
    eval "$(free -m | awk '/Mem:/{print "mt="$2"; mu="$3}')"
    kv "Memory" "$(bar $(( mu * 100 / mt )))  ${C_D}$(( mu / 1024 ))/$(( mt / 1024 )) GB"
  fi
  local dpct dused dtot davail
  df -h / 2>/dev/null | awk 'NR==2 {print $5, $3, $2, $4}' | read -r dpct dused dtot davail
  if (( compact )); then kv "Disk /" "$(bar ${dpct%\%})  ${C_D}${davail} free of ${dtot}"
  else kv "Disk /" "$(bar ${dpct%\%})  ${C_D}${dused} used of ${dtot}, ${davail} free"; fi
  if (( is_mac && $+commands[pmset] )); then
    local batt; batt="$(pmset -g batt 2>/dev/null | awk -F'\t' '/InternalBattery/{print $2}' | sed 's/ present.*//')"
    [[ -n $batt ]] && kv "Battery" "$batt"
  fi
  (( compact )) || kv "Processes" "$(ps -A | wc -l | tr -d ' ') running · $(ps -A -o user= | sort -u | wc -l | tr -d ' ') distinct users"
}

# default interface, gateway and private IP; shared by the network and route blocks
local iface="" gw="" private_ip="" ssid=""
net_basics() {
  if (( is_mac )); then
    route -n get default 2>/dev/null | awk '/interface:/{i=$2} /gateway:/{g=$2} END{print i, g}' | read -r iface gw
    private_ip=$(ipconfig getifaddr "${iface:-en0}" 2>/dev/null)
    ssid="$(ipconfig getsummary "${iface:-en0}" 2>/dev/null | awk -F': ' '/ SSID/{print $2; exit}')"
  else
    ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev")d=$(i+1); if($i=="via")g=$(i+1)}} END{print d, g}' | read -r iface gw
    private_ip=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
  fi
}

blk_network() {
  section "NETWORK"
  kv "Interface"  "${iface:-none}${ssid:+ · Wi-Fi \"$ssid\"}"
  kv "Private IP" "${C_INFO}${private_ip:-none}${C_RESET}  ${C_D}gateway ${gw:-none}"
  if (( ! compact )); then
    # every other interface with an IPv4 (VPNs, Tailscale, Docker, ...)
    local others
    if (( is_mac )); then
      others="$(ifconfig 2>/dev/null | awk -v skip="$iface" '
        /^[a-z]/ {i=$1; sub(":","",i)}
        /inet / && i!=skip && i!="lo0" {printf "%s=%s  ", i, $2}')"
    else
      others="$(ip -4 -o addr show 2>/dev/null | awk -v skip="$iface" '$2!=skip && $2!="lo" {split($4,a,"/"); printf "%s=%s  ", $2, a[1]}')"
    fi
    [[ -n $others ]] && kv "Other IPs" "$others"
  fi
  local dns
  if (( is_mac )); then
    dns="$(scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | sort -u | tr '\n' ' ')"
  else
    dns="$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
  fi
  kv "DNS" "${dns:-none}"
  if (( nonet )); then
    kv "Public IP" "${C_D}(skipped, --no-net)"
    return
  fi
  local pub pip="" porg pcity pregion pcountry phost
  pub="$(cached pubip $ttl curl -s -m 4 https://ipinfo.io/json)"
  [[ -n $pub ]] && pip=$(jq -r '.ip // empty' <<< "$pub" 2>/dev/null)
  if [[ -n $pip ]]; then
    porg=$(jq -r '.org // empty' <<< "$pub"); phost=$(jq -r '.hostname // empty' <<< "$pub")
    pcity=$(jq -r '.city // empty' <<< "$pub"); pregion=$(jq -r '.region // empty' <<< "$pub")
    pcountry=$(jq -r '.country // empty' <<< "$pub")
    kv "Public IP" "${C_INFO}${pip}${C_RESET}  ${C_D}${phost}"
    kv "ISP"       "${porg}  ${C_D}${pcity}, ${pregion} ${pcountry}"
  else
    pip="$(cached pubip2 $ttl curl -s -m 4 https://api.ipify.org)"
    kv "Public IP" "${C_INFO}${pip:-looking up… / offline}${C_RESET}"
  fi
  [[ -n $private_ip && -n $pip && $private_ip != $pip ]] && kv "NAT" "yes ${C_D}(${private_ip} → ${pip})"
  local sp; sp="$(speed_line inet)"
  [[ -n $sp ]] && kv "Speed" "$sp"
}

# Tailscale: this device, exit node, and every peer in the tailnet.
ts_query() {
  "$1" status --json 2>/dev/null | jq -r '
    def nm: ((.DNSName // "") | split(".")[0]) as $d | if ($d // "") == "" then .HostName else $d end;
    def ago: (now - .) as $s
      | if $s > 1e9 then "never"
        elif $s < 3600 then "\($s / 60 | floor)m ago"
        elif $s < 86400 then "\($s / 3600 | floor)h ago"
        else "\($s / 86400 | floor)d ago" end;
    "S|\(.BackendState)|\(.MagicDNSSuffix // "")|\(.Self | nm)|\(.Self.TailscaleIPs[0]? // "-")|\(.Self.Relay // "")|\([.Peer[]? | select(.ExitNode == true) | nm][0] // "")|\(.Health | length)",
    ([.Peer[]?] | sort_by([(.Online | not), nm]) | .[]
      | "P|\(nm)|\(.TailscaleIPs[0]? // "-")|\(.OS)|\(.Online)|\(if (.CurAddr // "") != "" then "direct" elif .Active then "relay \(.Relay)" else "idle" end)|\((.LastSeen // "0001-01-01T00:00:00Z") | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch 0) | ago)|\(.ExitNodeOption)")'
}
blk_tailscale() {
  local ts=${commands[tailscale]:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}
  [[ -x $ts ]] && (( $+commands[jq] )) || return 0
  section "TAILSCALE"
  local data; data="$(cached tailscale 20 ts_query "$ts")"
  if [[ -z $data ]]; then kv "Status" "${C_D}not running"; return; fi
  local -a rows=("${(@f)data}")
  local kind f1 f2 f3 f4 f5 f6 f7
  local -i total=0 online=0 shown=0 max=12
  (( compact )) && max=6
  local -a peers
  local nw=18 ow=8; (( compact )) && { nw=16; ow=6; }   # name and OS column widths
  for r in $rows; do
    IFS='|' read -r kind f1 f2 f3 f4 f5 f6 f7 <<< "$r"
    if [[ $kind == S ]]; then
      if [[ $f1 == Running ]]; then kv "Status" "${C_OK}● connected${C_D} · tailnet ${C_V}${f2}"
      else kv "Status" "${C_WARN}○ ${f1}"; fi
      local relay=""; (( compact )) || relay="${f5:+  relay $f5}"
      kv "This device" "${C_V}${f3}  ${C_INFO}${f4}${C_D}${relay}"
      [[ -n $f6 ]] && kv "Exit node" "${C_WARN}${f6}"
      (( f7 > 0 )) && kv "Health" "${C_WARN}${f7} warning(s) · run tailscale status"
    else
      (( total++ ))
      [[ $f4 == true ]] && (( online++ ))
      (( shown >= max )) && continue
      (( shown++ ))
      local exit_tag=""; [[ $f7 == true ]] && exit_tag=" ${C_D}(exit node)"
      if [[ $f4 == true ]]; then
        peers+=("$(printf "  %s● %s%-${nw}s %s%-15s %s%-${ow}s %s%s%s" "$C_OK" "$C_V" "$f1" "$C_INFO" "$f2" "$C_D" "$f3" "$C_OK" "$f5" "$exit_tag")")
      else
        peers+=("$(printf "  %s○ %-${nw}s %-15s %-${ow}s seen %s%s" "$C_D" "$f1" "$f2" "$f3" "$f6" "$exit_tag")")
      fi
    fi
  done
  kv "Peers" "${C_OK}${online} online${C_D} of ${total}"
  if [[ -n ${VICKS_IPERF_HOST:-} ]]; then
    local sp; sp="$(speed_line ts)"
    [[ -n $sp ]] && kv "Speed" "$sp"
  fi
  (( $#peers )) && print -rl -- "${peers[@]/%/$C_RESET}"
  (( total > shown )) && print -r -- "  ${C_D}… and $(( total - shown )) more · run tailscale status${C_RESET}"
}

blk_route() {
  # who owns the target: "AS15169 Google LLC" -> AS number and a short name
  local target_org="" target_as="" target_name=""
  if [[ $trace_stop == owner ]]; then
    target_org="$(cached "org_${target}" 86400 curl -s -m 2 "https://ipinfo.io/${target}/org")"
    [[ $target_org == *[\{\<]* ]] && target_org=""
    target_as=${target_org%% *}; target_name=${target_org#* }
    target_name=${target_name%,}; target_name=${${${${target_name% LLC}% Inc.}% Inc}% Ltd}
  fi
  if [[ $trace_stop == owner && -n $target_as ]]; then section "ROUTE TO INTERNET" "until it reaches ${target_name}"
  elif [[ $trace_stop == public ]]; then section "ROUTE TO INTERNET" "up to the first public address"
  else section "ROUTE TO INTERNET" "traceroute to ${target}"; fi
  local trace
  trace="$(cached "trace_${target}" $ttl traceroute -n -q 1 -w 1 -m 20 "$target")"
  if [[ -z $trace ]]; then
    if (( async )); then kv "Trace" "${C_D}tracing…"; else kv "Trace" "${C_BAD}no route / traceroute unavailable"; fi
    return
  fi
  if (( compact )); then
    printf "  %s%-3s %-16s %-8s %s%s\n" "$C_K" "hop" "address" "latency" "what it is" "$C_RESET"
  else
    printf "  %s%-4s %-18s %-10s %-9s %s%s\n" "$C_K" "hop" "address" "kind" "latency" "name" "$C_RESET"
  fi
  local hop addr ms rest cls col name lat org latcol
  local -i shown=0 reached=0
  print -r -- "$trace" | awk '$1 ~ /^[0-9]+$/' | while read -r hop addr ms rest; do
    if [[ $addr == '*' ]]; then
      if (( compact )); then printf "  %s%-3s %-16s %-8s%s\n" "$C_D" "$hop" "*" "no reply" "$C_RESET"
      else printf "  %s%-4s %-18s %-10s %-9s%s\n" "$C_D" "$hop" "*" "no reply" "-" "$C_RESET"; fi
      (( shown++ ))
      continue
    fi
    cls=$(ipclass "$addr")
    case $cls in
      private)    col=$C_INFO
        if [[ $addr == ${gw:-none} ]]; then name="your router (default gateway)"; (( compact )) && name="your router"
        else name="private address inside the ISP"; (( compact )) && name="private, inside the ISP"; fi ;;
      cgnat)      col=$C_WARN; name="ISP carrier-grade NAT (100.64/10)"; (( compact )) && name="ISP carrier-grade NAT" ;;
      link-local) col=$C_D;    name="link-local" ;;
      *)          col=$C_OK
        if [[ $addr == $target ]]; then name="destination"; org=$target_org
        else
          # network owner (AS number and organisation), plus the reverse DNS name
          name="$(cached "rdns_${addr}" 86400 dig +short +time=1 +tries=1 -x "$addr" | head -1)"; name=${name%.}
          org="$(cached "org_${addr}" 86400 curl -s -m 2 "https://ipinfo.io/${addr}/org")"
          [[ $org == *[\{\<]* ]] && org=""          # ignore error pages
          name="${org}${org:+${name:+ · }}${name}"
        fi ;;
    esac
    (( shown++ ))
    lat=${ms%.*}
    latcol=$C_OK; (( lat >= 30 )) && latcol=$C_WARN; (( lat >= 100 )) && latcol=$C_BAD
    if (( compact )); then
      printf "  %s%-3s %s%-16s %s%-8s %s%s%s\n" \
        "$C_V" "$hop" "$col" "$addr" "$latcol" "$(printf '%.1f' $ms) ms" "$C_D" "$name" "$C_RESET"
    else
      printf "  %s%-4s %s%-18s %s%-10s %s%-9s %s%s%s\n" \
        "$C_V" "$hop" "$col" "$addr" "$C_V" "$cls" "$latcol" "${ms} ms" "$C_D" "$name" "$C_RESET"
    fi
    # stop once the route is where the user wants to see it get to
    if [[ $cls == public ]]; then
      case $trace_stop in
        public) reached=1; break ;;
        owner)  if [[ $addr == $target || ( -n $target_as && ${org%% *} == $target_as ) ]]; then reached=1; break; fi ;;
      esac
    fi
  done
  mtime "$cache_dir/trace_${target}"; ago $(( EPOCHSECONDS - REPLY ))
  local summary
  if [[ $trace_stop == owner && -n $target_as ]]; then
    if (( reached )); then summary="reaches ${target_name} after ${shown} hops"
    else summary="${C_WARN}${target_name} not reached${C_D} · ${shown} hops shown"; fi
  elif [[ $trace_stop == public ]]; then
    if (( reached )); then summary="on the internet after ${shown} hops"
    else summary="${C_WARN}no public address reached${C_D}"; fi
  else summary="${shown} hops to ${target}"; fi
  if (( compact )); then
    printf "  %s%s · traced %s%s\n" "$C_D" "$summary" "$REPLY" "$C_RESET"
  else
    printf "  %s%s · traced %s · run %shello --fresh%s to refresh%s\n" "$C_D" "$summary" "$REPLY" "$C_V" "$C_D" "$C_RESET"
  fi
}

# ------------------------------------------------- speed test on demand ---
if (( speed_now )); then
  speedtests_start 1
  speed_tests
  print "Testing: ${(j:, :)reply:-nothing to test}. This takes up to half a minute."
  local name waited=0
  for name in $reply; do
    while [[ -f $cache_dir/speed_$name.lock ]] && (( waited++ < 90 )); do sleep 1; done
    case $name in
      inet) kv "Internet"  "$(speed_line inet)" ;;
      ts)   kv "Tailscale" "$(speed_line ts)" ;;
    esac
  done
  return 0 2>/dev/null || exit 0
fi

# a terminal window has just opened: start the once-per-window speed tests
(( new_window && ! once )) && speedtests_start 0

# Rotating tips: five lines at a time from a plain text file ("key | description").
# The page changes every VICKS_TIPS_SECONDS, so the pinned banner cycles through them.
#   blk_tips <width>   -> a block no wider than <width>
blk_tips() {
  local w=${1:-46} f=${VICKS_TIPS_FILE:-$here/cmux-tips.txt}
  [[ ${VICKS_TIPS:-1} != 0 && -r $f ]] || return 0
  # the default list is about cmux: show it only on a machine that has cmux, not over SSH
  if [[ -z ${VICKS_TIPS_FILE:-} ]]; then
    (( is_remote )) && return 0
    [[ -d /Applications/cmux.app ]] || (( $+commands[cmux] )) || return 0
  fi
  local -a tips=("${(@f)$(grep -vE '^[[:space:]]*(#|$)' "$f")}")
  local n=$#tips per=${VICKS_TIPS_COUNT:-5} secs=${VICKS_TIPS_SECONDS:-30}
  (( n > 0 && per > 0 && secs > 0 )) || return 0
  local pages=$(( (n + per - 1) / per ))
  local page=$(( (EPOCHSECONDS / secs) % pages ))
  local title="${VICKS_TIPS_TITLE:-CMUX TIPS}" count="$(( page + 1 ))/${pages}"
  local rule=$(( w - ${#title} - ${#count} - 2 )); (( rule < 0 )) && rule=0
  print -r -- "${C_Y}${C_BOLD}${title}${C_RESET} ${C_D}${count} $(rep ─ $rule)${C_RESET}"
  local -a keys descs
  local i t k d keyw=0
  for (( i = 0; i < per && i < n; i++ )); do
    t=${tips[$(( (page * per + i) % n + 1 ))]}
    k=${t%%|*}; d=${t#*|}
    k=${${k##[[:space:]]#}%%[[:space:]]#}; d=${${d##[[:space:]]#}%%[[:space:]]#}
    keys+=("$k"); descs+=("$d")
    (( ${#k} > keyw )) && keyw=${#k}
  done
  local room=$(( w - keyw - 2 ))
  for (( i = 1; i <= $#keys; i++ )); do
    d=$descs[i]; (( room > 3 && ${#d} > room )) && d="${d[1,room-1]}…"
    print -r -- "${C_INFO}${(r:keyw:: :)keys[i]}${C_RESET}  ${C_V}${d}${C_RESET}"
  done
}

# ---------------------------------------------------- one-shot banner ---
if (( ! dash )); then
  net_basics; proc_snapshot
  print
  blk_art
  print; blk_system
  print; blk_who
  print; blk_resources
  print; blk_top
  print; blk_network
  local ts_out; ts_out="$(blk_tailscale)"
  [[ -n $ts_out ]] && { print; print -r -- "$ts_out"; }
  (( nonet )) || { print; blk_route; }
  local tips_out; tips_out="$(blk_tips 46)"
  [[ -n $tips_out ]] && { print; print -r -- "$tips_out"; }
  print
  return 0 2>/dev/null || exit 0
fi

# ------------------------------------------------------ live dashboard ---
# flow <ncols> <minheight> <section>...  -> reply = one string per column.
# Sections are kept whole and spread so the columns end up about equally tall.
flow() {
  local n=$1; shift
  local -a secs=("$@") hs
  local s m=$#
  for s in "$@"; do hs+=($(( ${#${(f)s}} + 1 ))); done
  (( n > m )) && n=$m
  # hsum <from> <to> -> REPLY = total height of sections from..to
  hsum() { local k t=0; for (( k = $1; k <= $2; k++ )); do (( t += hs[k] )); done; REPLY=$t; }
  # try every way to cut the list into n runs; keep the one with the shortest tallest column
  local a b best=99999 mx h1 h2 h3 cut1=$(( m + 1 )) cut2=$(( m + 1 ))
  if (( n == 2 )); then
    for (( a = 2; a <= m; a++ )); do
      hsum 1 $(( a - 1 )); h1=$REPLY; hsum $a $m; h2=$REPLY
      mx=$(( h1 > h2 ? h1 : h2 ))
      (( mx < best )) && { best=$mx; cut1=$a; }
    done
  elif (( n >= 3 )); then
    for (( a = 2; a < m; a++ )); do
      for (( b = a + 1; b <= m; b++ )); do
        hsum 1 $(( a - 1 )); h1=$REPLY; hsum $a $(( b - 1 )); h2=$REPLY; hsum $b $m; h3=$REPLY
        mx=$(( h1 > h2 ? h1 : h2 )); (( h3 > mx )) && mx=$h3
        (( mx < best )) && { best=$mx; cut1=$a; cut2=$b; }
      done
    done
  fi
  reply=()
  local cur="" k
  for (( k = 1; k <= m; k++ )); do
    if (( k == cut1 || k == cut2 )); then reply+=("$cur"); cur=""; fi
    [[ -n $cur ]] && cur+=$'\n\n'
    cur+=$secs[k]
  done
  reply+=("$cur")
}

# render_dash <cols>  -> out = lines of one frame
local -a out
render_dash() {
  local cols=$1 colw=62 gap=2
  net_basics; proc_snapshot
  local s_art s_sys s_res s_top s_net s_ts s_route=""
  s_art="$(blk_art)"; s_sys="$(blk_system)"; s_res="$(blk_resources)"; s_top="$(blk_top)"
  s_net="$(blk_network)"; s_ts="$(blk_tailscale)"
  (( nonet )) || s_route="$(blk_route)"
  local -a secs=("$s_sys" "$s_res" "$s_top" "$s_net")
  [[ -n $s_ts ]] && secs+=("$s_ts")
  [[ -n $s_route ]] && secs+=("$s_route")

  local artw=0 arth=0 l
  for l in "${(@f)s_art}"; do vlen "$l"; (( REPLY > artw )) && artw=$REPLY; (( arth++ )); done
  # the tips fit in the empty space under the art, so they cost no extra rows there
  local s_art_tips="$s_art" s_tips
  s_tips="$(blk_tips $artw)"
  [[ -n $s_tips ]] && s_art_tips+=$'\n\n'"$s_tips"

  local -a C Wd        # column texts and widths
  local want_art=${VICKS_DASH_ART:-1}
  if (( side || cols < 2 * colw + gap )); then
    # one column: art on top when it fits, then every section
    (( want_art && cols >= artw && side )) && secs=("$s_art" "${secs[@]}")
    s_tips="$(blk_tips 46)"; [[ -n $s_tips ]] && secs+=("$s_tips")
    flow 1 "${secs[@]}"; C=("${reply[@]}"); Wd=($cols)
  elif (( want_art && cols >= artw + 2 * (52 + gap) )); then
    # art on the left, sections balanced over the remaining columns;
    # between 153 and 172 columns the two data columns shrink a little to make room
    local n=$(( (cols - artw) / (colw + gap) )); (( n > 3 )) && n=3
    if (( n < 2 )); then n=2; colw=$(( (cols - artw - 2 * gap) / 2 )); fi
    flow $n "${secs[@]}"
    C=("$s_art_tips" "${reply[@]}"); Wd=($artw); repeat $#reply Wd+=($colw)
  else
    local n=$(( (cols + gap) / (colw + gap) )); (( n > 3 )) && n=3
    s_tips="$(blk_tips 46)"; [[ -n $s_tips ]] && secs+=("$s_tips")
    flow $n "${secs[@]}"; C=("${reply[@]}"); repeat $#reply Wd+=($colw)
  fi

  local i j h=0 cell line pad empty=""
  local -a L
  for i in {1..$#C}; do L=("${(@f)C[i]}"); (( $#L > h )) && h=$#L; done
  out=()
  for j in {1..$h}; do
    line=""
    for i in {1..$#C}; do
      L=("${(@f)C[i]}")
      cell=${L[j]:-}
      vlen "$cell"
      if (( REPLY > Wd[i] )); then vtrunc "$cell" $Wd[i]; cell=$REPLY; pad=0
      else pad=$(( Wd[i] - REPLY )); fi
      line+="$cell"
      (( i < $#C )) && line+="${(l:pad+gap:: :)empty}"
    done
    out+=("$line")
  done
}

term_size() {   # -> rows cols
  if (( force_cols )); then rows=500; cols=$force_cols
  else stty size </dev/tty 2>/dev/null | read -r rows cols; fi
  : ${rows:=40} ${cols:=120}
}

local rows cols
if (( once )); then
  term_size; render_dash $cols
  print -rl -- "${out[@]}"
  return 0 2>/dev/null || exit 0
fi

local interval=${VICKS_DASH_INTERVAL:-5}
dash_cleanup() { print -n $'\e[?25h\e[?7h'; }
trap 'dash_cleanup; exit 0' INT TERM HUP
trap 'dash_cleanup' EXIT
print -n $'\e[?25l\e[?7l\e[2J'      # hide cursor, no line wrap, clear

local key buf last t wh ph want prev_size zoomed
while true; do
  term_size; prev_size="$rows $cols"
  render_dash $cols
  # side pane too short for everything: drop the art so the data fits
  if (( side && $#out > rows )); then VICKS_DASH_ART=0 render_dash $cols; fi
  fresh=0

  # inside tmux as the top pane: grow or shrink the pane to fit the content
  if [[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] && (( ! side )); then
    tmux display-message -p -t "$TMUX_PANE" '#{window_height} #{pane_height} #{window_zoomed_flag}' 2>/dev/null | read -r wh ph zoomed
    if [[ -n $wh && $zoomed != 1 ]]; then
      want=$#out; (( want > wh * 60 / 100 )) && want=$(( wh * 60 / 100 ))
      if (( want != ph && want > 2 )); then
        tmux resize-pane -t "$TMUX_PANE" -y $want 2>/dev/null
        rows=$want; prev_size="$rows $cols"
      fi
    fi
  fi

  last=$#out; (( last > rows )) && last=$rows
  buf=$'\e[H'
  for (( t = 1; t <= last; t++ )); do
    buf+="${out[t]}"$'\e[K'
    (( t < last )) && buf+=$'\n'
  done
  buf+=$'\e[J'
  print -rn -- "$buf"

  # wait, but react within a second to keys, resizes and the shell pane closing
  for (( t = 0; t < interval; t++ )); do
    key=""
    if [[ -t 0 ]]; then read -s -t 1 -k 1 key 2>/dev/null; else sleep 1; fi
    case $key in
      q) exit 0 ;;
      r) fresh=1; break ;;
    esac
    if [[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]]; then
      (( $(tmux list-panes -t "$TMUX_PANE" 2>/dev/null | wc -l) <= 1 )) && exit 0
    fi
    term_size; [[ "$rows $cols" != $prev_size ]] && break
  done
done
