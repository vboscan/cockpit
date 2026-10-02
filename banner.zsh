#!/usr/bin/env zsh
# banner.zsh — X-wing welcome banner with machine metadata and a route to the internet.
#
# Usage:  banner.zsh            (network parts are cached for $VICKS_CACHE_TTL seconds)
#         banner.zsh --fresh    (ignore the cache)
#         banner.zsh --no-net   (skip public IP lookup and traceroute)
#
# Env:    VICKS_ART=/path/to/file   alternative art file (tokens: {W} {G} {D} {R} {O} {C} {B} {Y} {X})
#         VICKS_CACHE_TTL=600       seconds to cache public IP + traceroute
#         VICKS_TRACE_TARGET=8.8.8.8

emulate -L zsh
setopt no_nomatch pipe_fail

# ---------------------------------------------------------------- colours ---
# 256-colour codes work in Terminal.app, iTerm2, Warp, VS Code, Ghostty, etc.
# Star Wars yellow is #FFE81F; use truecolor when the terminal advertises it.
local C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
local C_W=$'\e[38;5;255m'   # hull white
local C_G=$'\e[38;5;250m'   # hull grey
local C_D=$'\e[38;5;244m'   # dark grey
local C_R=$'\e[38;5;196m'   # red stripes (Red Squadron)
local C_O=$'\e[38;5;208m'   # engine glow (orange)
local C_C=$'\e[38;5;117m'   # canopy blue
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
local fresh=0 nonet=0
for a in "$@"; do
  case $a in
    --fresh)  fresh=1 ;;
    --no-net) nonet=1 ;;
  esac
done

local here=${0:A:h}
local art=${VICKS_ART:-$here/xwing.art}
local ttl=${VICKS_CACHE_TTL:-600}
local target=${VICKS_TRACE_TARGET:-8.8.8.8}
local cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/vicks
mkdir -p "$cache_dir" 2>/dev/null

local is_mac=0
[[ $OSTYPE == darwin* ]] && is_mac=1

# ---------------------------------------------------------------- helpers ---
# kv "label" "value"      -> aligned key/value line
kv() { printf "  %s%-14s%s %s%s%s\n" "$C_K" "$1" "$C_RESET" "$C_V" "$2" "$C_RESET"; }
# rep <char> <n>  -> char repeated n times (byte-safe in any locale)
rep() { local s=""; repeat ${2:-0} s+=$1; print -rn -- "$s"; }
# section "title" ["dim suffix"]
section() {
  local n=$(( 46 - ${#1} - ${#2} )); (( n < 3 )) && n=3
  printf "\n%s%s%s%s %s%s%s %s%s\n" "$C_Y" "$C_BOLD" "$1" "$C_RESET" "$C_D" "$2" "$C_RESET" "$C_D$(rep ─ $n)" "$C_RESET"
}
# bar <pct> [width]  -> coloured usage bar
bar() {
  local pct=${1%.*} width=${2:-20}; (( pct < 0 )) && pct=0; (( pct > 100 )) && pct=100
  local filled=$(( pct * width / 100 )) col=$C_OK
  (( pct >= 70 )) && col=$C_WARN
  (( pct >= 90 )) && col=$C_BAD
  printf "%s%s%s%s%s %3d%%" "$col" "$(rep █ $filled)" "$C_D" "$(rep ░ $((width - filled)))" "$C_RESET" "$pct"
}
# cached <name> <cmd...>  -> run cmd, cache stdout for $ttl seconds
cached() {
  local name=$1; shift
  local f=$cache_dir/$name
  if (( ! fresh )) && [[ -f $f ]]; then
    local age=$(( EPOCHSECONDS - $(zstat +mtime "$f" 2>/dev/null || stat -f %m "$f") ))
    if (( age < ttl )); then cat "$f"; return; fi
  fi
  "$@" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" && cat "$f"
}
zmodload zsh/datetime 2>/dev/null
zmodload -F zsh/stat b:zstat 2>/dev/null   # only zstat, keep the system `stat`
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

# ---------------------------------------------------------------- the art ---
print
if [[ -r $art ]]; then
  local line
  while IFS= read -r line; do
    line=${line//\{W\}/$C_W}; line=${line//\{G\}/$C_G}; line=${line//\{D\}/$C_D}
    line=${line//\{R\}/$C_R}; line=${line//\{O\}/$C_O}; line=${line//\{C\}/$C_C}
    line=${line//\{B\}/$C_B}; line=${line//\{Y\}/$C_Y}; line=${line//\{X\}/$C_RESET}
    print -r -- "    $line$C_RESET"
  done < "$art"
fi
print
print -r -- "  ${C_Y}${C_BOLD}May the Force be with you, ${USER}.${C_RESET}  ${C_D}Red Five standing by on $(hostname -s)${C_RESET}"

# ----------------------------------------------------------------- system ---
section "SYSTEM"
local os kernel model chip cpus mem_total
kernel="$(uname -s) $(uname -r) ($(uname -m))"
if (( is_mac )); then
  os="macOS $(sw_vers -productVersion) build $(sw_vers -buildVersion)"
  model="$(sysctl -n hw.model 2>/dev/null)"
  chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  cpus=$(sysctl -n hw.ncpu 2>/dev/null)
  mem_total=$(( $(sysctl -n hw.memsize) / 1024 / 1024 / 1024 ))
else
  os="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")"
  model="$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)"
  chip="$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  cpus=$(nproc 2>/dev/null)
  mem_total=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 ))
fi
kv "Host"     "$(hostname -s) ${C_D}($(hostname))"
(( is_mac )) && kv "Name" "$(scutil --get ComputerName 2>/dev/null)"
kv "OS"       "$os"
kv "Kernel"   "$kernel"
kv "Hardware" "${model:-?} · ${chip:-?} · ${cpus} cores · ${mem_total} GB RAM"
kv "Shell"    "zsh $ZSH_VERSION · ${TERM_PROGRAM:-${TERM:-unknown terminal}}"
kv "Date"     "$(date '+%A %d %B %Y, %H:%M %Z')"
kv "Uptime"   "$(uptime | sed -E 's/.* up +//; s/, +[0-9]+ users?.*//; s/  +/ /g')"

# ------------------------------------------------------------------ users ---
section "WHO IS HERE"
local me=$USER
local who_out; who_out="$(who 2>/dev/null)"
local -A sessions
local u
while read -r u _; do [[ -n $u ]] && (( sessions[$u]++ )); done <<< "$who_out"
for u in ${(ko)sessions}; do
  local tag=""; [[ $u == $me ]] && tag="${C_D}(you)"
  [[ $u != $me ]] && tag="${C_WARN}← someone else"
  kv "$u" "${sessions[$u]} session(s) $tag"
done
local remote; remote="$(print -r -- "$who_out" | awk '$NF ~ /^\(/ {print $1, $NF}' | sort -u)"
[[ -n $remote ]] && kv "Remote" "$(print -r -- "$remote" | tr '\n' ' ')"
[[ -n ${SSH_CONNECTION:-} ]] && kv "You via SSH" "${SSH_CONNECTION%% *} → ${SSH_CONNECTION##* }"
kv "Last login" "$(last -1 "$me" 2>/dev/null | awk 'NR==1{$1=""; print}' | sed 's/^ *//')"

# -------------------------------------------------------------- resources ---
section "RESOURCES"
local load cpu_pct mem_used_pct disk_line
load="$(uptime | sed -E 's/.*load averages?: //')"
# instantaneous CPU: sum of %cpu across processes / cores
cpu_pct=$(ps -A -o %cpu= | awk -v n="${cpus:-1}" '{s+=$1} END {printf "%d", s/n}')
if (( is_mac )); then
  local pg free_pg active wired compressed
  pg=$(sysctl -n hw.pagesize)
  eval "$(vm_stat | awk -F'[: .]+' '
    /Pages active/      {print "active="$3}
    /Pages wired/       {print "wired="$4}
    /occupied by compressor/ {print "compressed="$5}')"
  local used_gb; used_gb=$(( (active + wired + compressed) * pg / 1024 / 1024 / 1024 ))
  mem_used_pct=$(( used_gb * 100 / mem_total ))
  kv "CPU"    "$(bar $cpu_pct)  ${C_D}load $load"
  kv "Memory" "$(bar $mem_used_pct)  ${C_D}${used_gb}/${mem_total} GB (active+wired+compressed)"
else
  eval "$(free -m | awk '/Mem:/{print "mt="$2"; mu="$3}')"
  mem_used_pct=$(( mu * 100 / mt ))
  kv "CPU"    "$(bar $cpu_pct)  ${C_D}load $load"
  kv "Memory" "$(bar $mem_used_pct)  ${C_D}$(( mu/1024 ))/$(( mt/1024 )) GB"
fi
df -h / 2>/dev/null | awk 'NR==2 {print $5, $3, $2, $4}' | read -r dpct dused dtot davail
kv "Disk /" "$(bar ${dpct%\%})  ${C_D}${dused} used of ${dtot}, ${davail} free"
if (( is_mac )) && command -v pmset >/dev/null; then
  local batt; batt="$(pmset -g batt 2>/dev/null | awk -F'\t' '/InternalBattery/{print $2}' | sed 's/ present.*//')"
  [[ -n $batt ]] && kv "Battery" "$batt"
fi
kv "Processes" "$(ps -A | wc -l | tr -d ' ') running · $(ps -A -o user= | sort -u | wc -l | tr -d ' ') distinct users"

# ---------------------------------------------------------------- network ---
section "NETWORK"
local iface gw private_ip
if (( is_mac )); then
  route -n get default 2>/dev/null | awk '/interface:/{i=$2} /gateway:/{g=$2} END{print i, g}' | read -r iface gw
  private_ip=$(ipconfig getifaddr "${iface:-en0}" 2>/dev/null)
  local ssid; ssid="$(ipconfig getsummary "${iface:-en0}" 2>/dev/null | awk -F': ' '/ SSID/{print $2; exit}')"
else
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev")d=$(i+1); if($i=="via")g=$(i+1)}} END{print d, g}' | read -r iface gw
  private_ip=$(ip -4 -o addr show "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
fi
kv "Interface"  "${iface:-?}${ssid:+ · Wi-Fi \"$ssid\"}"
kv "Private IP" "${C_INFO}${private_ip:-?}${C_RESET}  ${C_D}gateway ${gw:-?}"
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
local dns
if (( is_mac )); then
  dns="$(scutil --dns 2>/dev/null | awk '/nameserver\[/{print $3}' | sort -u | tr '\n' ' ')"
else
  dns="$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ' ')"
fi
kv "DNS" "${dns:-?}"

if (( nonet )); then
  kv "Public IP" "${C_D}(skipped, --no-net)"
else
  local pub; pub="$(cached pubip curl -s -m 4 https://ipinfo.io/json)"
  if [[ -n $pub ]] && command -v jq >/dev/null; then
    local pip porg pcity pregion pcountry phost
    pip=$(jq -r '.ip // empty' <<< "$pub"); porg=$(jq -r '.org // empty' <<< "$pub")
    pcity=$(jq -r '.city // empty' <<< "$pub"); pregion=$(jq -r '.region // empty' <<< "$pub")
    pcountry=$(jq -r '.country // empty' <<< "$pub"); phost=$(jq -r '.hostname // empty' <<< "$pub")
    kv "Public IP" "${C_INFO}${pip}${C_RESET}  ${C_D}${phost}"
    kv "ISP"       "${porg}  ${C_D}${pcity}, ${pregion} ${pcountry}"
  else
    pub="$(cached pubip2 curl -s -m 4 https://api.ipify.org)"
    kv "Public IP" "${C_INFO}${pub:-unreachable}${C_RESET}"
  fi
  [[ -n $private_ip && -n ${pip:-$pub} && $private_ip != ${pip:-$pub} ]] && \
    kv "NAT" "yes ${C_D}(${private_ip} → ${pip:-$pub})"

  # -------------------------------------------------------------- route ---
  section "ROUTE TO INTERNET" "traceroute to ${target}"
  local trace
  trace="$(cached "trace_${target}" traceroute -n -q 1 -w 1 -m 20 "$target")"
  if [[ -z $trace ]]; then
    kv "Trace" "${C_BAD}no route / traceroute unavailable"
  else
    printf "  %s%-4s %-18s %-10s %-9s %s%s\n" "$C_K" "hop" "address" "kind" "latency" "name" "$C_RESET"
    local hop addr ms rest cls col name lat org
    print -r -- "$trace" | awk '$1 ~ /^[0-9]+$/' | while read -r hop addr ms rest; do
      if [[ $addr == '*' ]]; then
        printf "  %s%-4s %-18s %-10s %-9s %s%s\n" "$C_D" "$hop" "*" "no reply" "-" "" "$C_RESET"
        continue
      fi
      cls=$(ipclass "$addr")
      case $cls in
        private)    col=$C_INFO
          if [[ $addr == ${gw:-none} ]]; then name="your router (default gateway)"
          else name="private address inside the ISP"; fi;;
        cgnat)      col=$C_WARN; name="ISP carrier-grade NAT (100.64/10)";;
        link-local) col=$C_D;    name="link-local";;
        *)          col=$C_OK
          if [[ $addr == $target ]]; then name="destination"
          else
            # reverse DNS name, plus the network owner (AS number and organisation)
            name="$(cached "rdns_${addr}" dig +short +time=1 +tries=1 -x "$addr" | head -1)"; name=${name%.}
            org="$(cached "org_${addr}" curl -s -m 2 "https://ipinfo.io/${addr}/org")"
            [[ $org == *[\{\<]* ]] && org=""          # ignore error pages
            name="${org}${org:+${name:+ · }}${name}"
          fi;;
      esac
      lat="${ms%.*}"
      local latcol=$C_OK; (( lat >= 30 )) && latcol=$C_WARN; (( lat >= 100 )) && latcol=$C_BAD
      printf "  %s%-4s %s%-18s %s%-10s %s%-9s %s%s%s\n" \
        "$C_V" "$hop" "$col" "$addr" "$C_V" "$cls" "$latcol" "${ms} ms" "$C_D" "$name" "$C_RESET"
    done
    local hops; hops=$(print -r -- "$trace" | awk '$1 ~ /^[0-9]+$/' | wc -l | tr -d ' ')
    printf "  %s%s hops · cached for %ss · run %shello --fresh%s to refresh%s\n" "$C_D" "$hops" "$ttl" "$C_V" "$C_D" "$C_RESET"
  fi
fi
print
