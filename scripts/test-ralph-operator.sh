#!/usr/bin/env bash
# Behavioural tests for the standing operator: scripts/ralph-operator.sh, the
# journal in scripts/operator-lib.sh, and what the driver, heartbeat and
# notify.sh write to it. No network and no model: `tmux` is a stub on PATH whose
# sessions are files and whose panes show what was typed into them; the real
# claude-session.sh, heartbeat and driver run against it, with the front stubbed.
# Every fixture is a real git repository with a bare origin.
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0; root="$(mktemp -d)"
trap 'pkill -f "${root}/" 2>/dev/null; sleep 0.5; rm -rf "${root}" 2>/dev/null' EXIT
ok()  { pass=$((pass+1)); echo "  ok  — $1"; }
# Failures are repeated after the summary: CI's log tail (ci-status.sh) is 60 lines.
failures=""
bad() { fail=$((fail+1)); echo "  FAIL — $1"; echo "         $2"; failures+="  FAIL — $1: $(cut -c1-600 <<<"$2" | tr '\n' '|')"$'\n'; }
unset TMUX
mkdir -p "${root}/bin" "${root}/home"

# --- stub tmux -----------------------------------------------------------------
# A session is the file $TSTATE/s/<name>. new-session with a command runs it in
# the background and removes the file when it ends. A pane is what was typed into
# it, the remote-control URL, and a status bar that is busy unless idle.<name>
# exists or busy-count.<name> has run down to 0. on-enter.<name> runs once, on the
# Enter that submits the iteration prompt. display-message answers with the
# contents of me (the session a command is typed in, when TMUX is set).
# has-session is how the scripts ask whether a runner is live, and a runner can
# exit, or be kicked, at the instant they ask. Timing cannot place an event there
# (it did so 1 run in 4, which is how the race was found), so the stub does:
# pre-has.<name> runs once before the answer is taken, post-has.<name> once after
# it (the asker is left holding a stale answer); skip-has.<name> lets that many
# calls through first.
cat > "${root}/bin/tmux" <<'STUBEOF'
#!/usr/bin/env bash
trap '' PIPE # `capture-pane | grep -q` closes the pipe early; real tmux has written by then
S="${TSTATE}"; mkdir -p "${S}/s"
cmd=$1; shift
# A target names a session the way tmux 3.4 resolves it: an exact name, else the
# one session it is a prefix of (`ralph-x` finds `ralph-x-operator`), else none;
# `=name` is exact only. The live run of 2026-10-11 found `kick` refused for a
# "running" runner that was the operator's own session.
resolve() {
  local t=$1 m
  [[ $t == =* ]] && { t=${t#=}; [[ -e "${S}/s/${t}" ]] && echo "${t}"; return; }
  [[ -e "${S}/s/${t}" ]] && { echo "${t}"; return; }
  m=$(cd "${S}/s" 2>/dev/null && ls -d "${t}"* 2>/dev/null)
  [[ $(wc -l <<<"${m}") -eq 1 && -n ${m} ]] && echo "${m}"
}
case ${cmd} in
  has-session)
    r=$(resolve "$2"); [[ -n ${r} ]]; live=$?; set -- "$1" "${2#=}"
    n=0; [[ -f "${S}/skip-has.$2" ]] && read -r n < "${S}/skip-has.$2"
    if ((n > 0)); then echo $((n - 1)) > "${S}/skip-has.$2"
    elif [[ -f "${S}/pre-has.$2" ]]; then mv "${S}/pre-has.$2" "${S}/ran-has.$2"; bash "${S}/ran-has.$2"; [[ -e "${S}/s/$2" ]]; live=$?
    elif [[ -f "${S}/post-has.$2" ]]; then mv "${S}/post-has.$2" "${S}/ran-has.$2"; bash "${S}/ran-has.$2"
    fi
    exit "${live}" ;;
  new-session|new)
    name=""; dir=""; rest=()
    while (($#)); do case $1 in -d) ;; -s) name=$2; shift ;; -c) dir=$2; shift ;; -x|-y|-e) shift ;; *) rest+=("$1") ;; esac; shift; done
    [[ -e "${S}/s/${name}" ]] && { echo "duplicate session: ${name}" >&2; exit 1; }
    : > "${S}/s/${name}"
    if ((${#rest[@]})); then
      ( cd "${dir:-.}" && bash -c "${rest[*]}"; rm -f "${S}/s/${name}" ) >>"${S}/out.${name}" 2>&1 </dev/null &
    fi
    exit 0 ;;
  kill-session) rm -f "${S}/s/${2#=}"; exit 0 ;;
  list-sessions) ls "${S}/s" 2>/dev/null; exit 0 ;;
  display-message) cat "${S}/me" 2>/dev/null; exit 0 ;; # the caller's session: $TSTATE/me
  send-keys)
    name=${2#=}; name=${name%:}; shift 2
    { printf '%s' "${name}"; printf '\t%s' "$@"; printf '\n'; } >> "${S}/keys"
    for k in "$@"; do [[ $k == Enter ]] || printf '%s ' "$k" >> "${S}/typed.${name}"; done
    if [[ " $* " == *" Enter "* && -f "${S}/on-enter.${name}" ]] && grep -q 'Run one iteration per' "${S}/typed.${name}"; then
      mv "${S}/on-enter.${name}" "${S}/ran.${name}"; bash "${S}/ran.${name}"
    fi
    exit 0 ;;
  capture-pane)
    name=${2#=}
    n=$(cat "${S}/busy-count.${name}" 2>/dev/null || echo -1)
    if [[ -e "${S}/idle.${name}" ]] || ((n == 0)); then bar="⏵⏵ auto mode on"
    else bar="⏵⏵ auto mode on · esc to interrupt"; ((n > 0)) && echo $((n - 1)) > "${S}/busy-count.${name}"; fi
    typed=$(cat "${S}/typed.${name}" 2>/dev/null)
    # STUB_PASTE: render a typed operator prompt the way 2.1.289 folds a long one
    [[ -n ${STUB_PASTE:-} && ${typed} == *"Operator run"* ]] && typed="${typed%%Operator run*}[Pasted text #1]"
    printf '❯ %s\nhttps://claude.ai/code/session_%s\n%s\n' "${typed}" "${name//[^A-Za-z0-9]/}" "${bar}"
    exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
chmod +x "${root}/bin/tmux"
printf '#!/usr/bin/env bash\necho OK\n' > "${root}/bin/claude"; chmod +x "${root}/bin/claude"

# --- fixture -----------------------------------------------------------------
# mk <name>: a project with the kit's runner scripts, a stubbed front, preflight
# and notify (which journals exactly as notify.sh does), and a kit checkout.
mk() {
  P="${root}/$1"; O="${root}/$1.git"; T="${root}/$1.tmux"; stub="${root}/$1.stub"; KIT="${root}/$1.kit"
  mkdir -p "${T}" "${stub}" "${KIT}"
  git init -q --bare -b main "${O}"; git init -q -b main "${P}"
  ( cd "${P}" && git config user.email t@x && git config user.name t && git remote add origin "${O}"
    mkdir -p scripts ralph .ralph
    cp "${KIT_SCRIPTS}"/{ralph-operator,operator-lib,ralph-config,pane-busy,claude-session,ralph-heartbeat,ralph-driver,park-wip,usage-lib,usage-session,token-sentinel}.sh scripts/
    cp "${KIT_SCRIPTS}/../ralph/OPERATOR.md" ralph/ 2>/dev/null || echo "# operator" > ralph/OPERATOR.md
    cat > scripts/ralph-iterate.sh <<'FRONT'
#!/usr/bin/env bash
code=$(cat "${STUB}/front-exit" 2>/dev/null || echo 0)
[[ -f "${STUB}/front-prompt" ]] && echo "PROMPT=$(cat "${STUB}/front-prompt")" > "$(dirname "$0")/../.ralph/handoff"
((code == 0)) || "$(dirname "$0")/notify.sh" "ralph front stopped (exit ${code}): the stub's reason"
exit "${code}"
FRONT
    cat > scripts/notify.sh <<'NOTIFY'
#!/usr/bin/env bash
. "$(dirname "$0")/ralph-config.sh"; . "$(dirname "$0")/operator-lib.sh"
[[ $1 == -t ]] && shift 2
printf '%s\t%s\n' "${RALPH_NOTIFY_KIND:-notified}" "$*" >> "${STUB}/notify"
op_event "${RALPH_NOTIFY_KIND:-notified}" "$*"
[[ -e "${STUB}/notify-fail" ]] && exit 1 # the network is down: journaled, not delivered
exit 0
NOTIFY
    printf '#!/usr/bin/env bash\nexit 0\n' > scripts/preflight.sh
    chmod +x scripts/*.sh
    printf '.ralph/\n' > .gitignore
    printf ': "${RALPH_PROJECT_NAME:=fixture}"\n' > .ralph/config.sh
    git add -A && git commit -q -m init && git push -q -u origin main && git remote set-head origin main >/dev/null ) || echo "fixture $1 failed" >&2
  git -C "${KIT}" init -q
}
envs() { echo STUB="${stub}" TSTATE="${T}" PATH="${root}/bin:${PATH}" HOME="${root}/home" RALPH_KIT_DIR="${KIT}" \
  RALPH_OPERATOR_POLL=0.1 RALPH_OPERATOR_SETTLE=0.3 RALPH_OPERATOR_TICK=0.05 RALPH_ITER_POLL=1 RALPH_ITER_FLOOR=0 ${XENV:-}; }
# ops <args…>: the operator script in the current fixture; exit code in $st
ops() { ( cd "${P}" && env $(envs) timeout "${OPS_TIMEOUT:-60}" bash scripts/ralph-operator.sh "$@" >"${root}/out" 2>"${root}/err" ); st=$?; }
out() { cat "${root}/out"; }
why() { echo "exit ${st}; err: $(tail -3 "${root}/err"); out: $(head -12 "${root}/out" | tr '\n' '|')"; }
ev() { cut -f2 "${P}/.ralph/operator/events" 2>/dev/null | paste -sd' ' -; }
# a run with a live operator, without spawning one: what `start` leaves behind
fake_run() { mkdir -p "${P}/.ralph/operator"; printf 'RUN_ID=t\nKIT_DIR=%s\nARGS=%s\nSESSION=ralph-fixture-operator\nURL=https://claude.ai/code/session_ralphfixtureoperator\n' "${KIT}" "${1:--n 1}" > "${P}/.ralph/operator/run"; mkdir -p "${T}/s"; : > "${T}/s/ralph-fixture-operator"; }
event() { printf '%s\t%s\t%s\n' "$(date -Is)" "$1" "$2" >> "${P}/.ralph/operator/events"; }
runner_up() { : > "${T}/s/ralph-fixture"; }
runner_down() { rm -f "${T}/s/ralph-fixture"; }
# race <pre|post> <skip> <script>: run <script> at the runner's (<skip>+1)-th
# liveness check from now, before its answer is taken (pre) or after it (post).
race() { echo "$2" > "${T}/skip-has.ralph-fixture"; printf '%s\n' "$3" > "${T}/$1-has.ralph-fixture"; }
# till_stopped: wait (bounded) for a kicked runner to finish
till_stopped() { local i; for i in $(seq 1 1200); do [[ -e "${T}/s/ralph-fixture" ]] || return 0; sleep 0.1; done; return 1; }

echo "start"
mk s1; ops start -- -n 1
url="https://claude.ai/code/session_ralphfixtureoperator"
[[ $st -eq 0 ]] && out | grep -qx "URL=${url}" && out | grep -qx "SESSION=ralph-fixture-operator" && ok "start prints the operator's session and its remote-control URL" || bad "start output" "$(why)"
grep -q "has an operator — this is the run's one link: ${url}" "${stub}/notify" && grep -q "^info" "${stub}/notify" && ok "the owner is notified of the operator's link, as info (it wakes nobody)" || bad "start notify" "$(cat "${stub}/notify" 2>&1)"
launch=$(grep -P '^ralph-fixture-operator\tclaude ' "${T}/keys" | head -1 | cut -f2)
eval "argv=(${launch})"
want=("claude" "--permission-mode" "auto" "--model" "claude-opus-5-5" "--disallowedTools" "Edit(/${P}/**)" "Edit(/${KIT}/.claude/**)" "Edit(/${root}/home/.claude/settings.json)" "Edit(/${root}/home/.claude/settings.local.json)")
[[ "${argv[*]}" == "${want[*]}" ]] && ok "the launch line: auto mode, opus, a deny rule over the whole checkout, the kit's .claude/ and the settings files" || bad "launch line" "got: ${argv[*]}"
[[ ${launch} != *"Edit(/"* ]] && ok "the deny rules reach the pane's shell quoted, so nothing globs them" || bad "launch quoting" "${launch}"
grep -P '^ralph-fixture-operator\tOperator run [0-9T]+: read '"${P}"'/.ralph/operator/brief.md and follow it.$' "${T}/keys" >/dev/null && grep -P '^ralph-fixture-operator\tEnter$' "${T}/keys" >/dev/null && ok "a short prompt is typed and submitted" || bad "operator prompt" "$(grep -P '^ralph-fixture-operator' "${T}/keys" | tail -3)"
grep -q "protocol: ${P}/ralph/OPERATOR.md" "${P}/.ralph/operator/brief.md" && grep -q "Begin with: ${P}/scripts/ralph-operator.sh kick" "${P}/.ralph/operator/brief.md" && grep -q "kit checkout (where kit repairs are made): ${KIT}" "${P}/.ralph/operator/brief.md" && ok "the brief it points at names the protocol, the controls, the kit checkout and the first step" || bad "brief" "$(cat "${P}/.ralph/operator/brief.md" 2>&1)"
[[ "$(sed -n 's/^ARGS=//p' "${P}/.ralph/operator/run")" == "-n 1 " && "$(sed -n 's/^URL=//p' "${P}/.ralph/operator/run")" == "${url}" ]] && ok "the run file keeps the heartbeat's arguments and the link" || bad "run file" "$(cat "${P}/.ralph/operator/run")"
[[ ! -e "${T}/s/ralph-fixture" ]] && ok "start does not start the runner: the operator does" || bad "start kicked" "runner session exists"
ops start
[[ $st -eq 1 ]] && grep -q "one per run" "${root}/err" && ok "a second start while the operator is up: refused, one operator per run" || bad "second start" "$(why)"

mk s2; mkdir -p "${T}/s"; : > "${T}/s/ralph-fixture-sentinel"; ops start
[[ $st -eq 1 && ! -e "${P}/.ralph/operator/run" ]] && grep -q "sentinel" "${root}/err" && ok "start refuses while the sentinel runs: it would relaunch a stop before it is classified" || bad "sentinel" "$(why)"

mk s3; XENV="RALPH_KIT_DIR=${P}/kit" ; mkdir -p "${P}/kit"; ops start; XENV=""
[[ $st -eq 1 ]] && grep -q "inside this repository" "${root}/err" && ok "a kit checkout inside the project is refused: the operator could not write to it" || bad "kit inside" "$(why)"

mk s4; mkdir -p "${T}"; : > "${T}/idle.ralph-fixture-operator"; ops start
[[ $st -eq 1 && ! -e "${P}/.ralph/operator/run" && ! -e "${T}/s/ralph-fixture-operator" ]] && grep -q "never started a turn" "${root}/err" && ok "a prompt that never starts a turn: refused, session killed, no run left behind" || bad "never started" "$(why)"

mk s4b; XENV="STUB_PASTE=1"; ops start; XENV=""
[[ $st -eq 0 ]] && ok "a prompt the client folds into [Pasted text #1] counts as rendered (2.1.289)" || bad "pasted text" "$(why)"

mk s5;git init -q --bare "${root}/kit-origin.git"; rm -rf "${KIT}"; XENV="RALPH_KIT_REPO=${root}/kit-origin.git"; ops start; XENV=""
[[ $st -eq 0 && -d "${KIT}/.git" ]] && ok "a missing kit checkout is cloned from RALPH_KIT_REPO" || bad "kit clone" "$(why)"

echo "wait"
mk w1; fake_run; runner_up; event kick first; event worker "iter 1 started: https://claude.ai/code/session_W"
# One append, as the front's notice, the driver's exit and the runner's exit land within milliseconds.
ts=$(date -Is); ( sleep 0.5; printf '%s\t%s\t%s\n' "$ts" notified "a stop notice" "$ts" driver-exit "rc=1 iter=1 front=1" "$ts" runner-exit "rc=1 — driver stopped on merit" >> "${P}/.ralph/operator/events"; runner_down ) &
XENV="RALPH_OPERATOR_SETTLE=1"; ops wait; wait; XENV=""
[[ $st -eq 0 ]] && out | grep -qx "WAKE=runner-exit" && out | grep -q "^STOP=#5 runner-exit rc=1" && out | grep -q "^DRIVER=rc=1 iter=1 front=1" && out | grep -qP '^  \S+\tnotified\ta stop notice$' && ok "a runner exit wakes wait with the code and the driver's reason; the notice before it joins the same report" || bad "wait exit" "$(why)"
out | grep -q "^NEXT=classify" && out | grep -q "worker" && ok "the report says what to do next and carries the worker link" || bad "wait next" "$(out)"
ops wait
[[ $st -eq 3 ]] && out | grep -q "WAKE=none" && ok "the same events are not reported twice; nothing running: exit 3 at once" || bad "cursor" "$(why)"

# The same exit, placed at each liveness check of wait's first passes instead of
# left to the scheduler. Whichever read of the journal came before the check, the
# stop is reported once, as the exit it was.
for n in 0 1 2 3; do
  mk "r${n}"; fake_run; runner_up; event kick first; event worker "iter 1 started: https://claude.ai/code/session_W"
  race pre "${n}" "ts=\$(date -Is); printf '%s\t%s\t%s\n' \"\$ts\" notified 'a stop notice' \"\$ts\" driver-exit 'rc=1 iter=1 front=1' \"\$ts\" runner-exit 'rc=1 — driver stopped on merit' >> '${P}/.ralph/operator/events'; rm -f '${T}/s/ralph-fixture'"
  ops wait; first="$(why)"; st1=$st; out1="$(out)"
  ops wait
  [[ $st1 -eq 0 && $st -eq 3 && -e "${T}/ran-has.ralph-fixture" ]] && grep -qx "WAKE=runner-exit" <<<"${out1}" && grep -q "^STOP=#5 runner-exit rc=1" <<<"${out1}" && out | grep -q "WAKE=none" && [[ "$(ev)" == "kick worker notified driver-exit runner-exit" ]] \
    && ok "a runner that exits while wait checks on it (check $((n + 1))): one report, the exit it recorded, then nothing unread" || bad "exit race ${n}" "first wait: ${first} / second wait: $(why) / journal: $(ev)"
done

mk r4; fake_run; runner_up; event kick first
race post 0 "ts=\$(date -Is); printf '%s\t%s\t%s\n' \"\$ts\" runner-exit 'rc=1 — driver stopped on merit' >> '${P}/.ralph/operator/events'; rm -f '${T}/s/ralph-fixture'"
ops wait
[[ $st -eq 0 && "$(ev)" == "kick runner-exit" ]] && out | grep -qx "WAKE=runner-exit" && ok "and one that exits just after the check: the same report" || bad "exit after check" "$(why) / journal: $(ev)"

# The other edge of a runner: kick starts the session and then journals the kick.
# A check answered "not live" just before that must not turn the new kick into a
# vanished runner.
mk r5; fake_run; event kick first; event runner-exit "rc=1 — driver stopped on merit"; event classify "kind=transient — x"; event note "delivered=yes pr=none — x"
echo 4 > "${P}/.ralph/operator/cursor"
race post 0 ": > '${T}/s/ralph-fixture'; printf '%s\t%s\t%s\n' \"\$(date -Is)\" kick 'stop=2 kind=transient' >> '${P}/.ralph/operator/events'"
OPS_TIMEOUT=3 ops wait
[[ -e "${T}/ran-has.ralph-fixture" && "$(ev)" == "kick runner-exit classify note kick" ]] && ok "a kick that lands while wait checks on the runner is not recorded as a vanished runner" || bad "kick race" "$(why) / journal: $(ev)"

# Only a stop wakes the operator: a turn it takes to read "nothing to do" re-reads
# its whole context, every iteration (two a run's operator would otherwise take).
mk w2; fake_run; runner_up; event kick first
( sleep 0.3; event merged "iter 1: origin/main a -> b"; event notified "the implementer stopped for a human" ) &
OPS_TIMEOUT=3 ops wait; wait
[[ $st -eq 124 ]] && ok "a merge or a notice while the runner runs does not wake wait" || bad "wait merged" "$(why)"
event runner-exit "rc=1 — driver stopped on merit"; runner_down; ops wait
[[ $st -eq 0 ]] && out | grep -qx "WAKE=runner-exit" && out | grep -qP '\tmerged\titer 1' && out | grep -qP '\tnotified\tthe implementer stopped for a human' && ok "they are in the report of the stop that follows" || bad "merged in report" "$(why)"

mk w4; fake_run; runner_up; event kick first
for k in info worker iter-end note classify kick driver-exit merged notified posted handoff start; do event "$k" "x"; done
OPS_TIMEOUT=2 ops wait
[[ $st -eq 124 ]] && ok "info, worker links, merges, notices, a no-merge iteration end and the operator's own entries do not wake it" || bad "no wake" "$(why)"

mk w5; fake_run; runner_up; event kick first
event notified "usage limit hit during iter 1 — waiting for the pool"; event driver-exit "rc=2 iter=1 limit"
OPS_TIMEOUT=3 ops wait
[[ $st -eq 124 ]] && ok "a quota yield the heartbeat is handling does not wake it" || bad "limit yield" "$(why)"
# ...and its runner giving up at each liveness check wait makes around that yield.
for n in 0 1 2; do
  mk "y${n}"; fake_run; runner_up; event kick first
  event notified "usage limit hit during iter 1 — waiting for the pool"; event driver-exit "rc=2 iter=1 limit"
  race pre "${n}" "printf '%s\t%s\t%s\n' \"\$(date -Is)\" runner-exit 'rc=0 — heartbeat: ralph/STOP appeared while waiting — stopping' >> '${P}/.ralph/operator/events'; rm -f '${T}/s/ralph-fixture'"
  ops wait; first="$(why)"; st1=$st; out1="$(out)"
  ops wait
  [[ $st1 -eq 0 && $st -eq 3 && -e "${T}/ran-has.ralph-fixture" ]] && grep -qE "^WAKE=(notified,)?runner-exit$" <<<"${out1}" && grep -q "^STOP=#4 runner-exit rc=0" <<<"${out1}" && [[ "$(ev)" == "kick notified driver-exit runner-exit" ]] \
    && ok "a yielding runner that exits while wait checks on it (check $((n + 1))): the stop wakes it once" || bad "yield race ${n}" "first wait: ${first} / second wait: $(why) / journal: $(ev)"
done

mk w6; fake_run; event kick first
ops wait
[[ $st -eq 0 ]] && out | grep -qx "WAKE=runner-gone" && grep -q "recorded no exit" "${P}/.ralph/operator/events" && ok "a runner whose session vanished without an exit is a stop: runner-gone" || bad "runner gone" "$(why)"

mk w7; fake_run; runner_up; event kick first
( cd "${P}" && exec env $(envs) bash scripts/ralph-operator.sh wait >/dev/null 2>&1 ) & echo $! > "${root}/bgwait"; sleep 0.5
ops wait
[[ $st -eq 1 ]] && grep -q "another wait" "${root}/err" && ok "a second wait on the same run: refused" || bad "two waits" "$(why)"
kill "$(cat "${root}/bgwait")" 2>/dev/null

mk w8; ops wait
[[ $st -eq 1 ]] && ok "wait with no operator run: refused" || bad "wait no run" "$(why)"

echo "stops"
# The real heartbeat and driver, kicked by the operator; the front's exit code decides the stop.
mk k1; fake_run; echo 11 > "${stub}/front-exit"
ops kick
[[ $st -eq 0 ]] && till_stopped && ok "kick starts the runner in its tmux session" || bad "kick" "$(why)"
ops wait
[[ $st -eq 0 ]] && out | grep -q "^DRIVER=rc=0 iter=1 front=11" && out | grep -q "^CLASSIFIED=no (loop-right only: the front stopped for the owner (exit 11))" && ok "front exit 11: the report says the stop can only be loop-right" || bad "front 11 report" "$(why)"
ops kick
[[ $st -eq 1 ]] && grep -q "not classified" "${root}/err" && ok "no re-kick before the stop is classified" || bad "kick unclassified" "$(why)"
ops note "did nothing"
[[ $st -eq 1 ]] && grep -q "classification comes first" "${root}/err" && ok "no note before the classification" || bad "note first" "$(why)"
ops classify transient "it looked flaky"
[[ $st -eq 1 ]] && grep -q "can only be loop-right" "${root}/err" && ok "front exit 11 cannot be classified transient" || bad "11 transient" "$(why)"
ops classify broken "a script misread it"
[[ $st -eq 1 ]] && ok "nor broken" || bad "11 broken" "$(why)"
ops classify loop-right
[[ $st -eq 1 ]] && grep -q "needs its evidence" "${root}/err" && ok "a classification without evidence: refused" || bad "no evidence" "$(why)"
ops classify loop-right "front exit 11: owner gate 'spec 03 manual-validated' is unticked"
[[ $st -eq 0 ]] && ok "loop-right, with its evidence, is recorded" || bad "classify 11" "$(why)"
ops classify loop-right "again"
[[ $st -eq 1 ]] && grep -q "one classification per stop" "${root}/err" && ok "one classification per stop" || bad "reclassify" "$(why)"
ops kick
[[ $st -eq 1 ]] && grep -q "no incident note" "${root}/err" && ok "no re-kick before the incident note" || bad "kick no note" "$(why)"
: > "${stub}/notify"; ops note "changed nothing; the owner validates spec 03"
[[ $st -eq 0 ]] && grep -q "^note" "${stub}/notify" && grep -q "Kind: kind=loop-right — front exit 11" "${stub}/notify" && grep -q "Did: changed nothing" "${stub}/notify" && grep -q "PR: none" "${stub}/notify" && ok "one incident note: the stop, the kind with its evidence, what was done, the PR" || bad "note" "$(why) / $(cat "${stub}/notify")"
ops note "again"
[[ $st -eq 1 ]] && grep -q "one per stop" "${root}/err" && ok "a second note for the same stop: refused" || bad "second note" "$(why)"
ops kick
[[ $st -eq 1 ]] && grep -q "until the owner runs" "${root}/err" && ok "a loop-right stop stays stopped" || bad "kick loop-right" "$(why)"
ops release
# The same command from the operator's own session: nothing to tell it.
echo ralph-fixture-operator-2 > "${T}/me"; XENV="TMUX=stub"; ops release; XENV=""; rm -f "${T}/me"; st_self=$st
ops kick
[[ $st -eq 0 ]] && till_stopped && ok "after the owner's release, kick starts the runner again" || bad "release kick" "$(why)"
# The owner acted from a shell, so the operator (now #2) is told, as a submitted
# turn: it may have ended its turn with nothing to wait on (found live 2026-10-11).
typed=$(grep -P "^ralph-fixture-operator-2\tThe owner ran '(release|kick)' from the shell\. Run .*ralph-operator\.sh status and do what its NEXT says\.$" "${T}/keys" | cut -f2 | grep -oE "'(release|kick)'" | paste -sd' ' -)
[[ "${typed}" == "'release' 'kick'" ]] && grep -qP '^ralph-fixture-operator-2\tC-u$' "${T}/keys" && grep -qP '^ralph-fixture-operator-2\tEnter$' "${T}/keys" && ok "release and kick from a shell each reach the operator as a typed and submitted turn (draft cleared first)" || bad "nudge" "typed: ${typed} / $(grep -P '^ralph-fixture-operator-2' "${T}/keys" | tail -4)"
[[ $st_self -eq 0 && $(grep -cP "^ralph-fixture-operator-2\tThe owner ran 'release'" "${T}/keys") -eq 1 ]] && ok "the operator running release itself is not nudged" || bad "self nudge" "self exit ${st_self}; release lines: $(grep -cP "^ralph-fixture-operator-2\tThe owner ran 'release'" "${T}/keys")"

mk k2; fake_run; echo 1 > "${stub}/front-exit"; XENV="RALPH_MAX_RELAUNCHES=1"
ops kick; till_stopped; ops wait
[[ $st -eq 0 ]] && out | grep -q "^STOP=#.* runner-exit rc=1" && out | grep -q "^CLASSIFIED=no$" && ok "front exit 1: a merit stop, any kind allowed" || bad "merit report" "$(why)"
ops classify transient "prompt never started a turn; the pane shows a stray dialog"; ops note "re-kicked"; ops kick
[[ $st -eq 0 && $(wc -l < "${P}/.ralph/relaunches.log") -eq 1 ]] && till_stopped && ok "transient: re-kicked, and the kick is stamped in the heartbeat's relaunch log" || bad "transient kick" "$(why)"
ops wait; ops classify transient "the same"; ops note "tried to re-kick"; ops kick
[[ $st -eq 1 ]] && grep -q "relaunch budget" "${root}/err" && ok "transient re-kicks share RALPH_MAX_RELAUNCHES with the heartbeat: refused when spent" || bad "budget" "$(why)"
XENV=""

mk k3; fake_run; echo 1 > "${stub}/front-exit"
ops kick; till_stopped; ops wait; ops classify broken "ralph-driver.sh misreads an idle pane as busy"
[[ $st -eq 0 ]] && ok "broken is recorded with the kit's fingerprint on the default branch" || bad "classify broken" "$(why)"
ops note "fixed the kit"
[[ $st -eq 1 ]] && grep -q -- "--pr" "${root}/err" && ok "a broken stop's note must name its kit PR" || bad "broken no pr" "$(why)"
ops note --pr https://example.test/kit/pull/7 "fixed pane-busy, PR merged, installed"; ops kick
[[ $st -eq 1 ]] && grep -q "has not changed" "${root}/err" && ok "a broken stop does not re-kick until the kit on origin's default branch changes" || bad "broken unchanged" "$(why)"
( cd "${P}" && echo "# fixed" >> scripts/pane-busy.sh && git commit -qam "chore(ralph): kit abc — fix" && git push -q ); ops kick
[[ $st -eq 0 ]] && till_stopped && ok "and does once the fix is installed there" || bad "broken kick" "$(why)"

# A classification may change once, to loop-right, until the note. The trap it
# removes: broken, then no kit bug found — a broken note needs --pr, so the
# operator could neither note nor hand over.
mk k7; fake_run; echo 1 > "${stub}/front-exit"
ops kick; till_stopped; ops wait; ops classify broken "the driver seemed to misread the pane"
ops classify transient "on reflection, flaky"
[[ $st -eq 1 ]] && grep -q "only to loop-right" "${root}/err" && ok "a classified stop cannot be reclassified transient or broken" || bad "reclassify transient" "$(why)"
ops classify loop-right "no kit bug: the finding in the plan review is real, the owner decides"
[[ $st -eq 0 ]] && out | grep -q "reclassified broken -> loop-right" && [[ "$(ev)" == *"classify classify" ]] && ok "broken may become loop-right before the note; both classifications stay in the journal" || bad "reclassify loop-right" "$(why) / $(ev)"
ops classify loop-right "again"
[[ $st -eq 1 ]] && grep -q "already classified loop-right" "${root}/err" && ok "loop-right is final" || bad "loop-right again" "$(why)"
ops status
out | grep -q "^CLASSIFIED=loop-right" && ok "status shows the current classification" || bad "status reclassified" "$(out)"
: > "${stub}/notify"; ops note "changed nothing"
[[ $st -eq 0 ]] && grep -q "Kind: kind=loop-right was=broken — no kit bug" "${stub}/notify" && ok "the note needs no --pr any more, and says what the stop was first called" || bad "note reclassified" "$(why) / $(cat "${stub}/notify")"
ops classify loop-right "late"
[[ $st -eq 1 ]] && grep -q "already has its incident note" "${root}/err" && ok "nothing changes after the note" || bad "reclassify after note" "$(why)"
ops kick
[[ $st -eq 1 ]] && grep -q "until the owner runs" "${root}/err" && ok "a reclassified loop-right stop stays stopped" || bad "kick reclassified" "$(why)"

# Every spec done and the owner's STOP: loop-right only, like front exit 11.
mk k8; fake_run; echo 10 > "${stub}/front-exit"
ops kick; till_stopped; ops wait
[[ $st -eq 0 ]] && out | grep -q "^DRIVER=rc=0 iter=1 front=10 promise" && out | grep -q "^CLASSIFIED=no (loop-right only: every spec is done)" && ok "front exit 10 (every spec done): the report says loop-right only" || bad "front 10 report" "$(why)"
ops classify broken "the front must be wrong"
[[ $st -eq 1 ]] && grep -q "every spec is done" "${root}/err" && ok "every spec done cannot be classified broken" || bad "10 broken" "$(why)"
ops classify transient "flaky"
[[ $st -eq 1 ]] && ok "nor transient" || bad "10 transient" "$(why)"
ops classify loop-right "every spec is done; the owner adds specs or ends the run"
[[ $st -eq 0 ]] && ok "loop-right is accepted" || bad "10 loop-right" "$(why)"
mk k9; fake_run; event kick first; event driver-exit "rc=0 iter=2 promise"; event runner-exit "rc=0 — heartbeat: driver finished cleanly"
ops classify transient "flaky"
[[ $st -eq 1 ]] && grep -q "every spec is done" "${root}/err" && ok "the promise seen in the iteration's pane: loop-right only" || bad "promise classify" "$(why)"
mk k10; fake_run; event kick first; event driver-exit "rc=0 iter=1 stop-file"; event runner-exit "rc=0 — heartbeat: driver finished cleanly"
ops classify broken "x"
[[ $st -eq 1 ]] && grep -q "ralph/STOP stopped the driver" "${root}/err" && ok "a driver stopped by ralph/STOP, since removed: loop-right only" || bad "stop-file classify" "$(why)"

mk k4; fake_run; : > "${P}/ralph/STOP"; ops kick
[[ $st -eq 1 ]] && grep -q "ralph/STOP" "${root}/err" && ok "kick never runs past ralph/STOP" || bad "STOP" "$(why)"
rm -f "${P}/ralph/STOP"; event kick first; event runner-exit "rc=0 — heartbeat: ralph/STOP present"; : > "${P}/ralph/STOP"
ops classify transient "flaky"
[[ $st -eq 1 ]] && grep -q "ralph/STOP is present" "${root}/err" && ok "a stop under ralph/STOP can only be loop-right" || bad "STOP classify" "$(why)"
rm -f "${P}/ralph/STOP"
mk k5; ops kick
[[ $st -eq 1 ]] && grep -q "no operator run" "${root}/err" && ok "kick with no operator run: refused (an unattended loop starts as before)" || bad "kick no run" "$(why)"
mk k6; fake_run; : > "${T}/s/ralph-fixture-sentinel"; ops kick
[[ $st -eq 1 ]] && grep -q "sentinel" "${root}/err" && ok "kick refuses while the sentinel runs" || bad "kick sentinel" "$(why)"

echo "driver"
# A whole iteration: the front hands over, the iteration session merges, the
# driver stops at -n 1. Run with and without an operator.
iteration() {
  echo 0 > "${stub}/front-exit"; echo "Run one iteration per ralph/PROMPT.md: spec 01-x, slice 1/1." > "${stub}/front-prompt"
  cat > "${T}/on-enter.ralph-fixture-iter" <<HOOK
c="${root}/\$\$.clone"; git clone -q "${O}" "\$c" && git -C "\$c" -c user.email=t@x -c user.name=t commit -q --allow-empty -m "feat(01): x" && git -C "\$c" push -q origin HEAD:main
echo 1 > "${T}/busy-count.ralph-fixture-iter"
HOOK
}
mk d1; fake_run; iteration; ops kick; till_stopped; ops wait
[[ $st -eq 0 ]] && grep -qP '\tworker\titer 1 started \(claude-opus-5-5\): https://claude.ai/code/session_ralphfixtureiter' "${P}/.ralph/operator/events" && ! grep -q "started" "${stub}/notify" && ok "under a live operator, the iteration's link goes to the operator's journal, not to the owner" || bad "worker link" "$(why) / $(cat "${stub}/notify")"
grep -qP '\tmerged\titer 1: origin/main [0-9a-f]+ -> [0-9a-f]+' "${P}/.ralph/operator/events" && out | grep -qx "WAKE=runner-exit" && out | grep -qP '\tmerged\titer 1' && ok "the merge is journalled, and reported with the stop that follows" || bad "merged" "$(ev) / $(why)"
grep -qP '\tdriver-exit\trc=0 iter=1 max-iters' "${P}/.ralph/operator/events" && grep -qP '\trunner-exit\trc=0' "${P}/.ralph/operator/events" && ok "the driver's exit reason and the runner's code are on disk" || bad "exit reasons" "$(ev)"

mk d2; iteration
( cd "${P}" && env $(envs) bash scripts/ralph-driver.sh -n 1 >"${root}/out" 2>"${root}/err" ); st=$?
[[ $st -eq 0 ]] && grep -q "ralph iter 1 started (claude-opus-5-5): https://claude.ai/code/session_ralphfixtureiter" "${stub}/notify" && [[ ! -e "${P}/.ralph/operator" ]] && ok "no operator: the owner gets the iteration's link as before, and no journal is written" || bad "no operator" "$(why) / $(cat "${stub}/notify" 2>&1)"

mk d3; fake_run; rm -f "${T}/s/ralph-fixture-operator"; iteration
( cd "${P}" && env $(envs) bash scripts/ralph-driver.sh -n 1 >"${root}/out" 2>"${root}/err" ); st=$?
grep -q "ralph iter 1 started" "${stub}/notify" && ok "an operator whose session is gone reads nothing: the owner gets the link" || bad "dead operator" "$(why) / $(cat "${stub}/notify" 2>&1)"

mk d4; fake_run; echo 2 > "${stub}/front-exit"; XENV="RALPH_MAX_RELAUNCHES=0"; ops kick; till_stopped; XENV=""
grep -qP '\tdriver-exit\trc=2 iter=1 front=2' "${P}/.ralph/operator/events" && grep -qP '\trunner-exit\trc=1' "${P}/.ralph/operator/events" && ok "a quota yield is journalled with rc=2; a spent budget ends the runner with its code" || bad "limit" "$(ev)"

# The token sentinel (scripts/token-sentinel.sh): the iteration's transcript
# passes RALPH_TOKEN_CAP_IMPLEMENT while the pane is still busy.
mk d5; fake_run; iteration
cat > "${T}/on-enter.ralph-fixture-iter" <<HOOK
sid=\$(grep -oE -- '--session-id [0-9a-f-]+' "${T}/typed.ralph-fixture-iter" | awk '{print \$2}')
d="${root}/projects/\$(printf '%s' "${P}" | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "\$d"
for i in 1 2 3; do echo '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":10000,"output_tokens":300}}}' >> "\$d/\$sid.jsonl"; done
HOOK
XENV="RALPH_TRANSCRIPT_DIR=${root}/projects RALPH_TOKEN_CAP_IMPLEMENT=1000 RALPH_TOKEN_CAP_POLL=1 RALPH_USAGE_LEDGER=${root}/d5.ledger"
( cd "${P}" && env $(envs) timeout 60 bash scripts/ralph-driver.sh -n 1 >"${root}/out" 2>"${root}/err" ); st=$?; XENV=""
[[ $st -eq 1 ]] && grep -q "passed its token cap" "${root}/out" && grep -qE -- '--session-id [0-9a-f-]{36}' "${T}/typed.ralph-fixture-iter" && ok "the session is launched with a --session-id; past the implementer's cap the driver stops on merit (exit 1)" || bad "token cap" "$(why)"
[[ ! -e "${T}/s/ralph-fixture-iter" ]] && grep -qP '\tdriver-exit\trc=1 iter=1 token-cap' "${P}/.ralph/operator/events" && ok "the session is killed and the journal says token-cap" || bad "token-cap journal" "$(ev)"
grep -q "ralph token sentinel" "${stub}/notify" && grep -q '"stage": "implement"' "${root}/d5.ledger" && grep -q '"over_cap": true' "${root}/d5.ledger" && ok "the owner is told and the breach is an implement row marked over_cap" || bad "token-cap record" "$(cat "${stub}/notify") / $(cat "${root}/d5.ledger" 2>&1)"

echo "notify.sh and claude-session.sh"
mk n1; cp "${KIT_SCRIPTS}/notify.sh" "${P}/scripts/notify.sh"
nt() { ( cd "${P}" && env -i PATH="${root}/bin:${PATH}" HOME="${root}/home" TSTATE="${T}" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 "$@" bash scripts/notify.sh "a message" >/dev/null 2>&1 ); }
nt; [[ ! -e "${P}/.ralph/operator" ]] && ok "notify.sh with no operator run writes no journal" || bad "notify no run" "$(ls "${P}/.ralph")"
fake_run; nt; nt RALPH_NOTIFY_KIND=info
[[ "$(ev)" == "notified info" ]] && grep -q "fixture: a message" "${P}/.ralph/operator/events" && ok "under an operator it journals every message, with its kind, even when the post fails" || bad "notify journal" "$(ev)"

mk c1; ( cd "${P}" && env $(envs) bash scripts/claude-session.sh new plain "${P}" m1 >/dev/null 2>&1 )
[[ "$(grep -P '^plain\tclaude ' "${T}/keys" | cut -f2)" == "claude --permission-mode auto --model m1" ]] && ok "claude-session.sh new with no extra arguments types the same command as before" || bad "session unchanged" "$(grep plain "${T}/keys" | head -2)"

echo "context budget"
# The operator's own transcript: ~/.claude/projects/<its cwd, the kit checkout,
# every non-alphanumeric character as '-'>/<id>.jsonl. transcript <id> <url>
# <context> [turns]: its remote-control line names its link; every assistant turn
# carries <context> tokens (input 10 + cache write 100 + cache read the rest).
tdir() { echo "${root}/home/.claude/projects/$(printf '%s' "$(cd "${KIT}" && pwd -P)" | sed 's/[^A-Za-z0-9]/-/g')"; }
transcript() {
  local d i; d=$(tdir); mkdir -p "${d}"
  { printf '{"type":"system","subtype":"bridge_status","content":"/remote-control is active","url":"%s"}\n' "$2"
    for ((i = 0; i < ${4:-1}; i++)); do
      printf '{"type":"assistant","message":{"model":"claude-fable-5-1","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":%d,"output_tokens":50}}}\n' $(($3 - 110))
    done; } > "${d}/$1.jsonl"
}
# another session in the kit checkout that printed the link as text, with a far larger context
decoy() { mkdir -p "$(tdir)"; printf '{"type":"user","message":{"content":"{\\"url\\":\\"%s\\"}"}}\n{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":900000,"cache_creation_input_tokens":0,"output_tokens":1}}}\n' "$1" > "$(tdir)/decoy.jsonl"; }
url1="https://claude.ai/code/session_ralphfixtureoperator"; url2="${url1}2"; url3="${url1}3"
cur() { sed -n "s/^$1=//p" "${P}/.ralph/operator/run" | tail -1; }
gone() { local i; for i in $(seq 1 300); do [[ -e "${T}/s/$1" ]] || return 0; sleep 0.1; done; return 1; }
ledger="${root}/home/.config/fixture/usage.jsonl"

mk x1; fake_run; runner_up; event kick first; transcript op-1 "${url1}" 5000; decoy "${url1}"
ops status
[[ $st -eq 0 ]] && out | grep -qx "CONTEXT=5000/150000" && ok "the operator's context is read from its own transcript, found by its link in the kit checkout's transcript dir" || bad "context" "$(why)"
transcript op-1 "${url1}" 150001; event runner-exit "rc=1 — driver stopped on merit"; runner_down
ops wait
[[ $st -eq 4 ]] && out | grep -q "^WAKE=rotate" && out | grep -q "^NEXT=hand off: .*ralph-operator.sh handoff" && ok "past RALPH_OPERATOR_CTX_CAP (default 150000), wait returns ROTATE, exit 4, instead of waiting" || bad "rotate" "$(why)"
transcript op-1 "${url1}" 1000; ops wait
[[ $st -eq 0 ]] && out | grep -qx "WAKE=runner-exit" && ok "a stop unread at ROTATE is still unread for the next wait" || bad "rotate keeps the stop" "$(why)"
XENV="RALPH_OPERATOR_CTX_CAP=900"; ops wait; XENV=""
[[ $st -eq 4 ]] && ok "the cap is RALPH_OPERATOR_CTX_CAP" || bad "cap override" "$(why)"

mk x2; fake_run; runner_up; event kick first
ops status
out | grep -qx "CONTEXT=unknown/150000" && ok "no transcript found: the context is unknown and nothing rotates" || bad "no transcript" "$(why)"

echo "a fresh operator per incident"
want_for() { echo "claude --permission-mode auto --model claude-opus-5-5 --disallowedTools Edit(/${P}/**) Edit(/${KIT}/.claude/**) Edit(/${root}/home/.claude/settings.json) Edit(/${root}/home/.claude/settings.local.json)"; }
mk f1; ops start -- -n 1; transcript op-1 "${url1}" 3000 2
event kick first; event runner-exit "rc=1 — driver stopped on merit"
ops classify transient "the prompt never started a turn"
: > "${stub}/notify"; ops note "nothing to repair; the next operator re-kicks"
[[ $st -eq 0 && "$(cur SESSION)" == ralph-fixture-operator-2 && "$(cur URL)" == "${url2}" ]] && out | grep -q "^NEXT_OPERATOR=${url2}" && ok "note starts the next operator in a new session" || bad "successor" "$(why) / run: $(cat "${P}/.ralph/operator/run")"
launch=$(grep -P '^ralph-fixture-operator-2\tclaude ' "${T}/keys" | head -1 | cut -f2); eval "argv=(${launch})"
[[ "${argv[*]}" == "$(want_for)" ]] && ok "with the same launch line: opus and every deny rule" || bad "successor launch" "got: ${argv[*]}"
grep -q "^note" "${stub}/notify" && grep -qx "Next operator: ${url2}" "${stub}/notify" && ok "the incident note carries the link of the operator that handles the next stop" || bad "note link" "$(cat "${stub}/notify")"
b="${P}/.ralph/operator/brief.md"
grep -q "operator #2" "${b}" && grep -q "nothing to repair; the next operator re-kicks" "${b}" && grep -q "classify.*the prompt never started a turn" "${b}" && grep -q "Begin with: ${P}/scripts/ralph-operator.sh status" "${b}" && ok "its brief: its number, the stop, the classification and the note it inherits, and to begin with status" || bad "successor brief" "$(cat "${b}")"
ops link
[[ $st -eq 0 && "$(out)" == "${url2}" ]] && ok "ops link prints the new operator's link" || bad "link" "$(why)"
sleep 1.5
[[ -e "${T}/s/ralph-fixture-operator" ]] && ok "the noting session is not killed mid-turn" || bad "killed mid-turn" "gone"
: > "${T}/idle.ralph-fixture-operator"
gone ralph-fixture-operator && ok "once its turn has ended, it is retired" || bad "retire" "$(cat "${P}/.ralph/operator/retire.log" 2>&1)"
for i in $(seq 1 100); do grep -q '"session_id": "op-1"' "${ledger}" 2>/dev/null && break; sleep 0.1; done
python3 - "${ledger}" <<'PY' && ok "and its usage is an operator row in the ledger" || bad "ledger row" "$(cat "${ledger}" 2>&1)"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if '"op-1"' in l]
assert len(rows) == 1, rows
d = rows[0]; assert d["stage"] == "operator" and d["num_turns"] == 2 and d["output"] == 100 and d["cache_read"] == 2 * 2890, d
PY
echo ralph-fixture-operator > "${T}/me"; XENV="TMUX=stub"; ops kick; XENV=""
[[ $st -eq 1 ]] && grep -q "retired operator" "${root}/err" && ok "a retired operator's commands are refused" || bad "retired caller" "$(why)"
echo ralph-fixture-operator-2 > "${T}/me"; XENV="TMUX=stub"; ops classify transient "x"; XENV=""; rm -f "${T}/me"
! grep -q "retired" "${root}/err" && ok "the current operator's are not" || bad "current caller" "$(why)"

transcript op-2 "${url2}" 2000; : > "${stub}/notify"
ops handoff "the stop is noted; the runner is not re-kicked yet"
[[ $st -eq 0 && "$(cur SESSION)" == ralph-fixture-operator-3 ]] && grep -qP '\thandoff\t.*the runner is not re-kicked yet' "${P}/.ralph/operator/events" && ok "handoff journals the handoff and starts the next operator" || bad "handoff" "$(why)"
grep -q "^info.*the run's link is now: ${url3}" "${stub}/notify" && ok "and tells the owner the run's new link, as info" || bad "handoff link" "$(cat "${stub}/notify")"
grep -q "the runner is not re-kicked yet" "${b}" && ok "the successor's brief carries the handoff" || bad "handoff brief" "$(cat "${b}")"
ops link
[[ "$(out)" == "${url3}" ]] && ok "ops link follows the run across a rotation" || bad "link after handoff" "$(why)"
: > "${T}/idle.ralph-fixture-operator-2"; gone ralph-fixture-operator-2 && ok "the handing-off session is retired" || bad "handoff retire" "$(cat "${P}/.ralph/operator/retire.log" 2>&1)"

mk f2; ops start; event kick first; event runner-exit "rc=1 — driver stopped on merit"; ops classify transient "x"
: > "${T}/idle.ralph-fixture-operator-2"; : > "${stub}/notify"; ops note "re-kick"
[[ $st -eq 0 && "$(cur SESSION)" == ralph-fixture-operator && ! -e "${T}/s/ralph-fixture-operator-2" ]] && grep -q "Next operator: none" "${stub}/notify" && grep -qP '\tnote\t' "${P}/.ralph/operator/events" && out | grep -q "you remain the operator" && ok "a successor that does not start: the note is recorded and says so, and the operator stays" || bad "no successor" "$(why) / $(cat "${stub}/notify")"
sleep 1.5; [[ -e "${T}/s/ralph-fixture-operator" ]] && ok "and is not retired" || bad "retired without successor" "gone"

mk f3; fake_run; runner_up; event kick first; echo ralph-fixture-operator > "${T}/me"
( cd "${P}" && exec env $(envs) TMUX=stub timeout 30 bash scripts/ralph-operator.sh wait >"${root}/bgout" 2>&1 ) & bg=$!; sleep 0.5
printf 'SESSION=ralph-fixture-operator-2\nURL=%s\n' "${url2}" >> "${P}/.ralph/operator/run"
wait "${bg}"; st=$?; rm -f "${T}/me"
[[ $st -eq 1 ]] && grep -q "retired" "${root}/bgout" && ok "a retired operator's background wait ends instead of holding the run's wait" || bad "retired wait" "exit ${st}: $(cat "${root}/bgout")"

mk f4; ops start; transcript op-9 "${url1}" 4000 3; rm -f "${T}/s/ralph-fixture-operator"
ops start
[[ $st -eq 0 ]] && grep -q '"session_id": "op-9"' "${ledger}" && ok "the last operator of a run, never rotated, is in the ledger once the next run starts" || bad "ledger at start" "$(why) / $(grep op-9 "${ledger}")"

# The note is recorded and the successor started even when the post fails. But
# the successor's link was only in that note, and the old link dies with the
# retired operator: what did not reach the owner is kept, shown, and reposted.
mk f5; ops start; event kick first; event runner-exit "rc=1 — driver stopped on merit"; ops classify transient "x"
: > "${stub}/notify-fail"; : > "${stub}/notify"; ops note "re-kick"
und="${P}/.ralph/operator/undelivered"
[[ $st -eq 0 && "$(cur SESSION)" == ralph-fixture-operator-2 ]] && grep -q "could not post" "${root}/err" && grep -qP '\tposted\tdelivered=no' "${P}/.ralph/operator/events" && ok "a note notify.sh cannot post: recorded, delivered=no, the successor started all the same" || bad "undelivered note" "$(why)"
grep -qx "Next operator: ${url2}" "${und}" 2>/dev/null && ok "the undelivered note is kept, with the successor's link" || bad "undelivered kept" "$(cat "${und}" 2>&1)"
ops status
out | grep -qx "UNDELIVERED=1 message(s)" && out | grep -q "^NEXT=repost what did not reach the owner: ${P}/scripts/ralph-operator.sh repost" && ok "status shows it and makes the repost the next step" || bad "status undelivered" "$(out)"
ops repost
[[ $st -eq 1 && -e "${und}" ]] && grep -q "could not post" "${root}/err" && ok "repost while the network is still down: refused, the message kept" || bad "repost down" "$(why)"
transcript op-2 "${url2}" 2000; ops handoff "the stop is noted"
[[ $st -eq 0 && "$(cur SESSION)" == ralph-fixture-operator-3 ]] && grep -q "the run's link is now: ${url3}" "${und}" && [[ $(grep -c "Next operator: ${url2}" "${und}") -eq 1 ]] && ok "an undelivered handoff link joins the kept messages" || bad "undelivered handoff" "$(why) / $(cat "${und}" 2>&1)"
rm -f "${stub}/notify-fail"; : > "${stub}/notify"; ops repost
[[ $st -eq 0 && ! -e "${und}" ]] && grep -q "^note" "${stub}/notify" && grep -q "Next operator: ${url2}" "${stub}/notify" && grep -q "the run's link is now: ${url3}" "${stub}/notify" && grep -qP '\tposted\tdelivered=yes repost' "${P}/.ralph/operator/events" && ok "repost sends every kept message as one note and clears them" || bad "repost" "$(why) / $(cat "${stub}/notify")"
ops status
! out | grep -q "^UNDELIVERED" && ok "status is quiet again" || bad "status after repost" "$(out)"
ops repost
[[ $st -eq 1 ]] && grep -q "nothing undelivered" "${root}/err" && ok "repost with nothing kept: refused" || bad "repost empty" "$(why)"
: > "${T}/idle.ralph-fixture-operator"; : > "${T}/idle.ralph-fixture-operator-2"

echo "operator budget"
# row <ledger> <hours ago> <weighted> [stage]: one ledger row, as usage-session.sh writes it
row() { mkdir -p "$(dirname "$1")"; printf '{"ts":"%s","spec":"ops","slice":"r","stage":"%s","weighted":%d}\n' "$(date -u -d "-$2 hours" +%Y-%m-%dT%H:%M:%SZ)" "${4:-operator}" "$3" >> "$1"; }
mk b1; L="${root}/b1.ledger"; row "${L}" 1 2000000; row "${L}" 2 1000001; row "${L}" 1 9000000 implement
XENV="RALPH_USAGE_LEDGER=${L}"; ops start; XENV=""
[[ $st -eq 1 && ! -e "${P}/.ralph/operator/run" && ! -e "${T}/s/ralph-fixture-operator" ]] && grep -q "operator budget is spent: 3000001 of 3000000" "${root}/err" && ok "start refuses once operators used RALPH_OPERATOR_DAILY_BUDGET (3M weighted) in 24 h; other stages do not count" || bad "budget at start" "$(why)"
mk b2; L="${root}/b2.ledger"; row "${L}" 25 9000000; row "${L}" 1 100
XENV="RALPH_USAGE_LEDGER=${L}"; ops start; XENV=""
[[ $st -eq 0 ]] && ok "the window is a rolling 24 h" || bad "budget window" "$(why)"
mk b3; L="${root}/b3.ledger"; row "${L}" 1 9000000
XENV="RALPH_USAGE_LEDGER=${L} RALPH_OPERATOR_DAILY_BUDGET=0"; ops start; XENV=""
[[ $st -eq 0 ]] && ok "a budget of 0 is no budget" || bad "budget off" "$(why)"

mk b4; L="${root}/b4.ledger"; XENV="RALPH_USAGE_LEDGER=${L}"; ops start
# the current operator's own transcript counts before it is on the ledger: 30M cache read = 3M weighted
transcript op-1 "${url1}" 30000110 1; event kick first; event runner-exit "rc=1 — driver stopped on merit"
ops status
out | grep -qx "BUDGET=3000460/3000000 (24 h, weighted)" && ok "status shows what operators spent, the live one included" || bad "budget status" "$(why)"
ops classify transient "x"; : > "${stub}/notify"; ops note "re-kick"
[[ $st -eq 0 && "$(cur SESSION)" == ralph-fixture-operator && ! -e "${T}/s/ralph-fixture-operator-2" ]] && grep -q "Next operator: none: the operator budget is spent" "${stub}/notify" && grep -qP '\tbudget\t' "${P}/.ralph/operator/events" && ok "a spent budget: the note says so and starts no operator" || bad "budget at note" "$(why) / $(cat "${stub}/notify")"
: > "${T}/idle.ralph-fixture-operator"; gone ralph-fixture-operator && ok "and the noting operator is retired all the same: the stop waits for the owner" || bad "budget retire" "$(cat "${P}/.ralph/operator/retire.log" 2>&1)"
XENV=""

mk b5; L="${root}/b5.ledger"; XENV="RALPH_USAGE_LEDGER=${L}"; ops start; transcript op-1 "${url1}" 30000110 1; : > "${stub}/notify"
ops handoff "context cap"
[[ $st -eq 0 && ! -e "${T}/s/ralph-fixture-operator-2" ]] && grep -q "^notified.*operator budget is spent" "${stub}/notify" && ok "a handoff on a spent budget starts no operator and tells the owner, as a notice" || bad "budget at handoff" "$(why) / $(cat "${stub}/notify")"
: > "${T}/idle.ralph-fixture-operator"; gone ralph-fixture-operator && ok "and retires the one handing off" || bad "budget handoff retire" "-"
XENV=""

echo "kit checkout state"
# Each operator starts in whatever its predecessor left in the kit checkout; the
# brief and status say what that is, and change nothing.
mk g1; KO="${root}/g1-kit.git"; git init -q --bare -b main "${KO}"
( cd "${KIT}" && git checkout -q -b main && git -c user.email=t@x -c user.name=t commit -q --allow-empty -m a && git remote add origin "${KO}" && git push -q -u origin main && git remote set-head origin main >/dev/null )
ops start
grep -qx -- "- Kit checkout state: main, 0 uncommitted, 0 behind and 0 ahead of origin/main" "${P}/.ralph/operator/brief.md" && ok "the brief gives the kit checkout's branch, local changes and distance from origin" || bad "kit state in brief" "$(cat "${P}/.ralph/operator/brief.md")"
c="${root}/g1-other"; git clone -q "${KO}" "${c}"; for i in 1 2; do git -C "${c}" -c user.email=t@x -c user.name=t commit -q --allow-empty -m "o${i}"; done; git -C "${c}" push -q origin main
( cd "${KIT}" && git checkout -q -b fix/x && git -c user.email=t@x -c user.name=t commit -q --allow-empty -m half && echo x > half-done.sh && echo y > notes.txt && git add half-done.sh )
before="$(git -C "${KIT}" status --porcelain; git -C "${KIT}" rev-parse HEAD; git -C "${KIT}" branch --show-current)"
ops status
out | grep -qx "KIT=fix/x, 2 uncommitted, 2 behind and 1 ahead of origin/main" && ok "status shows a half-done repair left in the kit checkout" || bad "kit state in status" "$(why)"
[[ "$(git -C "${KIT}" status --porcelain; git -C "${KIT}" rev-parse HEAD; git -C "${KIT}" branch --show-current)" == "${before}" ]] && ok "and changes nothing there" || bad "kit state changed" "$(git -C "${KIT}" status --short)"
mk g2; fake_run; ops status
out | grep -qx "KIT=master, 0 uncommitted (no origin to compare with)" || out | grep -qx "KIT=main, 0 uncommitted (no origin to compare with)" && ok "a kit checkout with no origin: no distance, no error" || bad "kit no origin" "$(why)"

echo "ledger rows"
mk l1; L="${root}/l1.ledger"; fake_run; rm -f "${T}/s/ralph-fixture-operator"; transcript op-7 "${url1}" 4000 2
XENV="RALPH_USAGE_LEDGER=${L}"
( cd "${P}" && env $(envs) bash scripts/ralph-operator.sh _retire ralph-fixture-operator "${url1}" >/dev/null 2>&1 ) &
( cd "${P}" && env $(envs) bash scripts/ralph-operator.sh _retire ralph-fixture-operator "${url1}" >/dev/null 2>&1 ) &
wait
ops start
[[ "$(grep -c '"op-7"' "${L}")" -eq 1 ]] && ok "two retirements of one session and the next start: one ledger row" || bad "ledger once" "$(cat "${L}")"
XENV=""

echo "  ${pass} passed, ${fail} failed"; printf '%s' "${failures}"; [[ $fail -eq 0 ]]
