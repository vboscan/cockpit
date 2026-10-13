#!/usr/bin/env bash
# ANCHOR: ralph-operator — a standing operator for a run, one session per incident
# (docs/coordinator-split.md "The standing operator"; protocol: ralph/OPERATOR.md).
#
#   ralph-operator.sh start [--kit DIR] [-- <heartbeat args>]   the owner: spawn the
#                      first operator, print its link (a run hands the owner only
#                      its operators' links)
#   ralph-operator.sh kick                     start the runner (heartbeat + driver)
#   ralph-operator.sh wait                     block until the runner stops; print a
#                      report. Run it in the background: waiting costs nothing.
#   ralph-operator.sh classify transient|broken|loop-right <evidence>
#   ralph-operator.sh note [--pr <url>] <what was done>     the one incident note. It
#                      starts the next operator, names its link, retires this one
#   ralph-operator.sh handoff <the state>      what `wait`'s ROTATE asks for: the same
#                      hand-over, with no stop to note
#   ralph-operator.sh release                  the owner: let a loop-right stop re-kick
#   ralph-operator.sh repost                   post what notify.sh could not: a note or a
#                      new link kept in .ralph/operator/undelivered
#   ralph-operator.sh link                     the current operator's link
#   ralph-operator.sh status
#
# What the script holds, so the protocol does not have to:
#   - the operator session is launched with a deny rule over every write under
#     this checkout, its kit checkout's .claude/ and the user's settings files
#   - a stop (the runner exiting, or its session vanishing) must be classified,
#     then noted, before `kick` will start the runner again; a classification
#     changes only to loop-right, and only before the note
#   - front exit 11 (the owner's), every spec done and ralph/STOP can only be
#     classified loop-right, and a loop-right stop re-kicks only after `release`
#   - a transient re-kick spends the heartbeat's own relaunch budget
#     (RALPH_MAX_RELAUNCHES per rolling 24 h, .ralph/relaunches.log)
#   - a broken re-kick needs a PR in its note and the kit on origin's default
#     branch to have changed since the stop was classified
#   - one session per incident: `note` and `handoff` start a fresh operator and
#     retire the calling one once its turn ends; a retired operator's commands are
#     refused, and its background `wait` ends
#   - a context cap: past RALPH_OPERATOR_CTX_CAP, `wait` reports ROTATE instead
#     of waiting (the operator's own transcript, the last turn's context)
#   - a spend cap: past RALPH_OPERATOR_DAILY_BUDGET (operators' weighted tokens in
#     24 h) no operator is started, by `start`, `note` or `handoff`
#   - only a stop wakes `wait`: a merge or a notice is read with the next stop,
#     not by a turn that re-reads the whole context to conclude "wait again"
#   - a note or a new link that notify.sh could not post is kept, shown as
#     UNDELIVERED, and `repost` is the next step: the owner's old link dies with
#     the retired operator, and the new one was only in that message
#
# Exit: 0 done · 1 refused, the reason on stderr · 3 wait: the runner is not
# running and nothing is unread · 4 wait: ROTATE · 64 usage.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ralph-config.sh
. "$HERE/ralph-config.sh"
# shellcheck source=scripts/operator-lib.sh
. "$HERE/operator-lib.sh"
# shellcheck source=scripts/pane-busy.sh
. "$HERE/pane-busy.sh" # pane_busy
# shellcheck source=scripts/usage-lib.sh
. "$HERE/usage-lib.sh" # transcript_dirs
ROOT="$RALPH_REPO_ROOT"
STOP_FILE="$ROOT/ralph/STOP"
LOCK_FILE="$ROOT/.ralph/heartbeat.lock"
RELAUNCH_LOG="$ROOT/.ralph/relaunches.log"
MAX_RELAUNCHES="${RALPH_MAX_RELAUNCHES:-3}"
POLL="${RALPH_OPERATOR_POLL:-15}"     # seconds between journal reads in `wait`
SETTLE="${RALPH_OPERATOR_SETTLE:-20}" # gather what follows a wake into one report
TICK="${RALPH_OPERATOR_TICK:-5}"      # prompt-start checks in `start`
GRACE="${RALPH_OPERATOR_RETIRE_GRACE:-600}" # seconds a retired operator may finish its turn
CTX_CAP="$RALPH_OPERATOR_CTX_CAP"
BUDGET="$RALPH_OPERATOR_DAILY_BUDGET"

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 64; }
refuse() { echo "ralph-operator: REFUSED — $*" >&2; exit 1; }
run_get() { sed -n "s/^$1=//p" "$OP_RUN" 2>/dev/null | tail -1; }
# =name: an exact match. Without it tmux answers for a session the name only
# prefixes: ralph-x is live whenever ralph-x-operator is (found live, 2026-10-11).
sess_live() { tmux has-session -t "=$1" 2>/dev/null; }
lock_held() { [[ -e $LOCK_FILE ]] && ! flock -n "$LOCK_FILE" true 2>/dev/null; }
runner_live() { sess_live "$RALPH_TMUX_SESSION" || lock_held; }
# the same, by listing: kept for the kill path, where a name that resolves to
# the wrong session (a retired operator's to its successor's) must never be acted on
sess_exact() { tmux list-sessions -F '#S' 2>/dev/null | grep -qxF -- "$1"; }
op_count() { grep -c '^SESSION=' "$OP_RUN" 2>/dev/null || true; }
# the tmux session this command was typed in, if it was typed in one
caller_session() { [[ -n ${TMUX:-} ]] && tmux display-message -p '#S' 2>/dev/null; }
# retired <session> — an earlier operator of this run, not the current one
retired() { [[ -n $1 && $1 != "$(op_session)" ]] && grep -qxF "SESSION=$1" "$OP_RUN" 2>/dev/null; }
refuse_retired() {
  local me; me=$(caller_session) || true
  retired "$me" && refuse "this session ($me) is a retired operator; the run's operator is $(op_session) ($(run_get URL)). End your turn"
  return 0
}
# nudge <what the owner ran> — an owner's command from the shell reaches the
# run's operator as a turn in its session. An operator whose NEXT was "nothing
# until the owner acts" has ended its turn with nothing to `wait` on, so a
# release and a kick typed in a shell, and the stop that followed, sat unread for
# 30 minutes (claude_sandbox, 2026-10-11, stop #8). Typed the way `start` types
# the first prompt: a line, Enter, and Enter again while no turn has started.
# Nothing is typed when the caller is the operator itself or no operator is up.
nudge() {
  local sess i
  sess=$(op_session)
  [[ $(caller_session) != "$sess" ]] || return 0
  sess_live "$sess" || return 0
  tmux send-keys -t "=$sess:" C-u # an unsent draft would otherwise prefix the line
  tmux send-keys -t "=$sess:" "The owner ran '$1' from the shell. Run $HERE/ralph-operator.sh status and do what its NEXT says."
  for i in 1 2 3 4 5 6; do
    tmux send-keys -t "=$sess:" Enter
    sleep "$TICK"
    pane_busy "$(tmux capture-pane -t "=$sess:" -p)" && return 0
  done
  return 0
}

# --- the operator's own transcript --------------------------------------------------
# The client keeps it under the operator's cwd, its kit checkout, not the project:
# ~/.claude/projects/<kit, non-alphanumerics as ->/<id>.jsonl. Its id is not on the
# pane; its remote-control line names its link as a JSON field ("url":"…"). Other
# sessions there, a predecessor that printed this link or a `claude -p` review,
# carry it only inside a string, where the quotes are escaped.
op_transcript() { # <url> → the path, or nothing
  local d
  [[ -n ${1-} ]] || return 0
  while IFS= read -r d; do
    [[ -d $d ]] || continue
    grep -lF "\"url\":\"$1\"" "$d"/*.jsonl 2>/dev/null | head -1 | grep . && return 0
  done < <(transcript_dirs "$(run_get KIT_DIR)")
  return 0
}

# op_context — the current operator's context: its last main-thread turn's input +
# cache read + cache write. "unknown" when its transcript is not found.
op_context() {
  local f n=""
  f=$(op_transcript "$(run_get URL)")
  [[ -n $f ]] && n=$(python3 - "$f" <<'PY'
import json, sys
n = None
for line in open(sys.argv[1], errors="ignore"):
    if '"usage"' not in line: continue
    try: d = json.loads(line)
    except ValueError: continue
    u = (d.get("message") or {}).get("usage") if d.get("type") == "assistant" and not d.get("isSidechain") else None
    if u: n = u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)
if n is not None: print(n)
PY
)
  echo "${n:-unknown}"
}
over_cap() { local c; c=$(op_context); [[ $c =~ ^[0-9]+$ ]] && ((c > CTX_CAP)); }

# op_spent — operators' weighted tokens in the last 24 h: this project's ledger
# rows of stage `operator`, plus the current operator, not on the ledger until it
# is retired. The ledger is per project; the pool it draws on is the account's.
op_spent() {
  local f=""
  grep -qxF "LEDGERED=$(op_session)" "$OP_RUN" 2>/dev/null || f=$(op_transcript "$(run_get URL)")
  usage_py - "$RALPH_USAGE_LEDGER" "$f" <<'PY'
import json, os, sys, time
ledger, live = sys.argv[1:3]
w = {k: float(os.environ[f"RALPH_W_{k.upper()}"]) for k in ("input", "cache_read", "cache_write", "output")}
cut = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 86400))
n = 0.0
try:
    for line in open(ledger):
        try: d = json.loads(line)
        except ValueError: continue
        if d.get("stage") == "operator" and d.get("ts", "") >= cut: n += float(d.get("weighted") or 0)
except OSError: pass
if live:
    for line in open(live, errors="ignore"):
        if '"usage"' not in line: continue
        try: d = json.loads(line)
        except ValueError: continue
        u = (d.get("message") or {}).get("usage") if d.get("type") == "assistant" else None
        if u: n += (u.get("input_tokens", 0) * w["input"] + u.get("cache_read_input_tokens", 0) * w["cache_read"]
                    + u.get("cache_creation_input_tokens", 0) * w["cache_write"] + u.get("output_tokens", 0) * w["output"])
print(round(n))
PY
}
# budget_spent — true when the budget is set and spent; SPENT holds the figure
budget_spent() { SPENT=$(op_spent); ((BUDGET > 0 && SPENT >= BUDGET)); }

# --- the journal ---------------------------------------------------------------
# ev_last <kind-regex> [after-line] [before-line] — "<line>\t<ts>\t<kind>\t<text>"
ev_last() {
  awk -F'\t' -v k="^($1)\$" -v a="${2:-0}" -v b="${3:-0}" \
    'NR > a && (b == 0 || NR < b) && $2 ~ k { l = NR "\t" $0 } END { if (l) print l }' "$OP_EVENTS" 2>/dev/null
}
ev_line() { cut -f1 <<<"$1"; }
ev_text() { cut -f4- <<<"$1"; }

# reconcile — a runner whose session is gone with no exit recorded (killed, or
# the box restarted) is a stop too; record it so it is classified like any other.
#
# Sets WAS_LIVE (1 or empty): the runner's liveness, sampled between the two reads
# of the journal, because the runner moves while they are made and each read has
# one safe side of the sample:
#   - `kick` starts the session and then journals the kick, so a kick read BEFORE
#     the sample belongs to a runner that had started by then;
#   - `_runner` journals its exit and then its session ends, so a read made AFTER
#     a "not live" sample holds every event that runner wrote.
# Sampled after both reads, as it was, a runner that journalled its exit and went
# away in between was recorded as gone on top of its own exit.
reconcile() {
  local kick
  kick=$(ev_last kick) || true
  WAS_LIVE=""; runner_live && WAS_LIVE=1
  [[ -n $kick ]] || return 0
  [[ -z $(ev_last 'runner-exit|runner-gone' "$(ev_line "$kick")") ]] || return 0
  [[ -n $WAS_LIVE ]] || op_event runner-gone "the runner's session ($RALPH_TMUX_SESSION) is gone and recorded no exit"
}

# The latest stop and what has been recorded against it. Sets STOP_LINE (empty
# when there is none since the last kick), STOP_TEXT, KIND, KIT_AT, NOTED, RELEASED.
load_stop() {
  local s kick c
  STOP_LINE="" STOP_TEXT="" KIND="" KIT_AT="" NOTED="" RELEASED=""
  s=$(ev_last 'runner-exit|runner-gone')
  [[ -n $s ]] || return 0
  kick=$(ev_last kick)
  [[ -n $kick && $(ev_line "$kick") -gt $(ev_line "$s") ]] && return 0 # re-kicked since
  STOP_LINE=$(ev_line "$s"); STOP_TEXT="$(cut -f3 <<<"$s") $(ev_text "$s")"
  c=$(ev_last classify "$STOP_LINE")
  if [[ -n $c ]]; then
    KIND=$(ev_text "$c" | sed -n 's/^kind=\([a-z-]*\).*/\1/p')
    KIT_AT=$(ev_text "$c" | sed -n 's/^kind=[a-z-]* kit=\([0-9a-f]*\).*/\1/p')
  fi
  [[ -n $(ev_last note "$STOP_LINE") ]] && NOTED=1
  [[ -n $(ev_last release "$STOP_LINE") ]] && RELEASED=1
  return 0
}

# driver_exit — the driver's last recorded exit before the latest stop.
driver_exit() {
  local kick
  kick=$(ev_last kick 0 "$STOP_LINE")
  ev_text "$(ev_last driver-exit "$(ev_line "${kick:-0}")" "$STOP_LINE")"
}

# owners_stop — the reason a stop can only be loop-right, or nothing.
owners_stop() {
  local d; d=$(driver_exit)
  if [[ -e $STOP_FILE ]]; then echo "ralph/STOP is present"
  elif [[ $d == *front=11* ]]; then echo "the front stopped for the owner (exit 11)"
  elif [[ $d == *front=10* || $d == *promise* ]]; then echo "every spec is done"
  elif [[ $d == *stop-file* ]]; then echo "ralph/STOP stopped the driver"
  fi
}

relaunches_left() {
  local cutoff used=0
  cutoff=$(($(date +%s) - 86400))
  [[ -f $RELAUNCH_LOG ]] && used=$(awk -v c="$cutoff" '$1 > c' "$RELAUNCH_LOG" | wc -l)
  echo $((MAX_RELAUNCHES - used))
}

# What notify.sh could not post is kept here, one message after another, each
# under a "## <what> <ts>" line; `repost` sends the file as one note and clears it.
UNDELIVERED="$OP_DIR/undelivered"
keep_undelivered() { # <what> <message>
  printf '## %s %s\n%s\n\n' "$1" "$(date -Is)" "$2" >>"$UNDELIVERED"
}
undelivered_count() { grep -c '^## ' "$UNDELIVERED" 2>/dev/null || echo 0; }

# kit_state — the kit checkout as the last operator left it: its branch, its
# uncommitted files, and its distance from origin's default branch. Read-only but
# for a fetch: a successor sees a half-done repair before it builds on one.
kit_state() {
  local kit br n ref counts behind ahead
  kit=$(run_get KIT_DIR)
  git -C "$kit" rev-parse --git-dir >/dev/null 2>&1 || { echo "$kit is not a git checkout"; return 0; }
  br=$(git -C "$kit" symbolic-ref --quiet --short HEAD) || br="detached at $(git -C "$kit" rev-parse --short HEAD 2>/dev/null)"
  n=$(git -C "$kit" status --porcelain 2>/dev/null | wc -l)
  timeout 20 git -C "$kit" fetch -q origin 2>/dev/null || true
  ref=$(git -C "$kit" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || ref=origin/main
  if counts=$(git -C "$kit" rev-list --left-right --count "$ref...HEAD" 2>/dev/null); then
    read -r behind ahead <<<"$counts"
    echo "$br, $n uncommitted, $behind behind and $ahead ahead of $ref"
  else
    echo "$br, $n uncommitted (no origin to compare with)"
  fi
}

# kit_tree — a fingerprint of the kit as installed on origin's default branch.
kit_tree() {
  local ref
  git -C "$ROOT" fetch -q origin 2>/dev/null || true
  ref=$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
  git -C "$ROOT" ls-tree -r "$ref" -- scripts ralph .claude/skills 2>/dev/null | sha256sum | cut -c1-16
}

summary() {
  load_stop
  echo "RUNNER=$(runner_live && echo running || echo stopped)"
  if [[ -z $STOP_LINE ]]; then echo "STOP=none"; else
    echo "STOP=#$STOP_LINE $STOP_TEXT"
    echo "DRIVER=$(driver_exit)"
    local must; must=$(owners_stop)
    if [[ -z $KIND ]]; then echo "CLASSIFIED=no${must:+ (loop-right only: $must)}"
    else echo "CLASSIFIED=$KIND NOTED=${NOTED:+yes}${NOTED:-no}${RELEASED:+ RELEASED=yes}"; fi
  fi
  echo "RELAUNCHES_LEFT=$(relaunches_left)/$MAX_RELAUNCHES"
  echo "CONTEXT=$(op_context)/$CTX_CAP"
  [[ -s $UNDELIVERED ]] && echo "UNDELIVERED=$(undelivered_count) message(s)"
  return 0
}

next_step() {
  load_stop
  if [[ -s $UNDELIVERED ]]; then echo "NEXT=repost what did not reach the owner: $HERE/ralph-operator.sh repost — then status again"
  elif [[ -z $STOP_LINE ]]; then runner_live && echo "NEXT=wait again" || echo "NEXT=kick"
  elif [[ -z $KIND ]]; then echo "NEXT=classify the stop: $HERE/ralph-operator.sh classify <transient|broken|loop-right> <evidence>"
  elif [[ -z $NOTED ]]; then echo "NEXT=post the incident note: $HERE/ralph-operator.sh note [--pr <url>] <what you did>"
  elif [[ $KIND == loop-right && -z $RELEASED ]]; then echo "NEXT=nothing: the loop stays stopped until the owner acts"
  else echo "NEXT=kick when the repair is in"; fi
}

# --- commands --------------------------------------------------------------------
cmd_start() {
  local kit="$RALPH_KIT_DIR" rid url
  while (($#)); do
    case $1 in
      --kit) kit="${2-}"; [[ -n $kit ]] || usage; shift ;;
      --) shift; break ;;
      *) usage ;;
    esac
    shift
  done
  { sess_live "$RALPH_OPERATOR_SESSION" || op_live; } && refuse "an operator is already running for this checkout: tmux session $(op_session) — one per run"
  sess_live "$RALPH_SENTINEL_SESSION" && refuse "the sentinel ($RALPH_SENTINEL_SESSION) is running: it relaunches a stopped heartbeat before anyone classifies the stop. Stop it first; under an operator, the operator replaces it"
  runner_live && refuse "a runner is already running ($RALPH_TMUX_SESSION): touch ralph/STOP and let it end, then start the operator"
  if [[ ! -d $kit ]]; then
    mkdir -p "$(dirname "$kit")" && git clone -q "$RALPH_KIT_REPO" "$kit" \
      || refuse "no kit checkout at $kit and cloning $RALPH_KIT_REPO failed"
  fi
  kit="$(cd "$kit" && pwd -P)"
  case "$kit/" in "$(cd "$ROOT" && pwd -P)/"*) refuse "the kit checkout $kit is inside this repository, where the operator may not write" ;; esac

  if [[ -d $OP_DIR ]]; then # the previous run's journal, kept for post-mortems
    ledger_all # its last operator was never retired, so never recorded
    mkdir -p "$ROOT/.ralph/logs"
    mv "$OP_DIR" "$ROOT/.ralph/logs/operator-$(run_get RUN_ID || true)-$(date +%s)"
  fi
  mkdir -p "$OP_DIR"
  rid=$(date +%Y%m%dT%H%M%S)
  {
    echo "RUN_ID=$rid"
    echo "KIT_DIR=$kit"
    echo "MODEL=$RALPH_OPERATOR_MODEL"
    printf 'ARGS=%s\n' "$( (($#)) && printf '%q ' "$@")"
  } >"$OP_RUN"
  url=$(spawn 1 "") || { rm -f "$OP_RUN"; exit 1; }
  RALPH_NOTIFY_KIND=info "$HERE/notify.sh" "ralph: run $rid has an operator — this is the run's one link: $url" >/dev/null 2>&1 || true
  echo "SESSION=$(op_session)"
  echo "URL=$url"
}

# spawn <n> <how #n-1 ended> — launch operator #n of this run with its brief and
# print its link. On failure: the reason on stderr, what it started killed,
# nothing recorded, exit 1; exit 2 when the operator budget is spent.
spawn() {
  local n=$1 why=$2 kit rid name out sess url i started=""
  if budget_spent; then
    echo "ralph-operator: REFUSED — the operator budget is spent: $SPENT of $BUDGET weighted tokens in 24 h (RALPH_OPERATOR_DAILY_BUDGET)" >&2
    return 2
  fi
  kit=$(run_get KIT_DIR); rid=$(run_get RUN_ID)
  name=$RALPH_OPERATOR_SESSION; ((n > 1)) && name+="-$n"
  local rules=() r
  while IFS= read -r r; do rules+=("$r"); done < <(deny_rules "$kit")
  out=$("$HERE/claude-session.sh" new "$name" "$kit" "$RALPH_OPERATOR_MODEL" -- --disallowedTools "${rules[@]}") \
    || { echo "ralph-operator: REFUSED — could not spawn the operator session" >&2; return 1; }
  sess=$(sed -n 's/^SESSION=//p' <<<"$out"); url=$(sed -n 's/^URL=//p' <<<"$out")
  abandon() { "$HERE/claude-session.sh" kill "$sess" >/dev/null 2>&1; echo "ralph-operator: REFUSED — $1" >&2; }

  # The prompt that is typed stays short and points at a file: the client folds
  # a long typed text into "[Pasted text #1]" (observed on 2.1.289), and the
  # paths in it are as long as the checkout's.
  brief "$n" "$why" "$kit" >"$OP_DIR/brief.md"
  tmux send-keys -t "$sess" "Operator run $rid: read $OP_DIR/brief.md and follow it."
  sleep "$TICK"
  tmux capture-pane -t "$sess" -p | grep -qE "Operator run $rid|\[Pasted text #[0-9]+" \
    || { abandon "the operator's prompt did not render in $sess"; return 1; }
  tmux send-keys -t "$sess" Enter
  for i in 1 2 3 4 5 6; do
    sleep "$TICK"
    if pane_busy "$(tmux capture-pane -t "$sess" -p)"; then started=1; break; fi
    tmux send-keys -t "$sess" Enter
  done
  [[ -n $started ]] || { abandon "the operator's prompt never started a turn in $sess"; return 1; }

  { echo "SESSION=$sess"; echo "URL=$url"; } >>"$OP_RUN"
  op_event start "operator #$n $sess on $RALPH_OPERATOR_MODEL: $url"
  echo "$url"
}

# brief <n> <why> <kit> — what operator #n reads first. A successor gets no
# conversation, only the record: the journal and its latest incident.
brief() {
  local n=$1 why=$2 kit=$3
  cat <<BRIEF
# Operator run $(run_get RUN_ID), operator #$n

You are the operator of the Ralph loop for $RALPH_PROJECT_NAME, for one incident.

- Project checkout (you may read it, never write it): $ROOT
- Your protocol: $ROOT/ralph/OPERATOR.md — read it now and follow it.
- Your controls (\`ops\`): $HERE/ralph-operator.sh
- Your kit checkout (where kit repairs are made): $kit
- Kit checkout state: $(kit_state)
BRIEF
  if ((n == 1)); then printf '\nBegin with: %s kick\n' "$HERE/ralph-operator.sh"; return 0; fi
  cat <<BRIEF

Operator #$((n - 1)) ended $why. None of its conversation is yours: the journal
($OP_EVENTS) is the record. Off the default branch or with uncommitted files,
the kit checkout holds work it left: read it before you build on it. The
journal's latest entries:

$(awk -F'\t' '$2 ~ /^(kick|runner-exit|runner-gone|classify|note|release|handoff)$/' "$OP_EVENTS" 2>/dev/null | tail -n 8 | cut -f1-3 | cut -c1-700 | sed 's/^/    /')

Begin with: $HERE/ralph-operator.sh status — then do what its NEXT says.
BRIEF
}

# retire <session> <url> — end an operator once its turn is over (or after
# RALPH_OPERATOR_RETIRE_GRACE), then record its usage. Detached: the session
# that asks is usually the one retired, and the asking command must return.
retire() {
  [[ -n ${1-} ]] || return 0
  setsid -f bash "$HERE/ralph-operator.sh" _retire "$1" "$2" >>"$OP_DIR/retire.log" 2>&1 </dev/null
}
cmd__retire() {
  local s=$1 url=$2 t=0
  while ((t < GRACE)) && sess_exact "$s" && pane_busy "$(tmux capture-pane -t "$s" -p 2>/dev/null)"; do
    sleep 1; t=$((t + 1))
  done
  # kill_one, not `claude-session.sh kill`: that refuses the session hosting the
  # caller, and tmux names the most recent session as the caller's when it has none
  # shellcheck source=scripts/claude-session.sh
  sess_exact "$s" && (export CLAUDE_SESSION_LIB_ONLY=1; . "$HERE/claude-session.sh"; kill_one "$s")
  # shellcheck disable=SC2031 # the subshell above sources claude-session.sh; its names stay there
  ledger "$s" "$url"
}

# ledger <session> <url> — the operator's usage as one `operator` row, once:
# the check and the row under one lock, as a retirement and the next run's start
# can reach the same session together.
ledger() {
  (
    flock 9
    grep -qxF "LEDGERED=$1" "$OP_RUN" 2>/dev/null && exit 0
    f=$(op_transcript "$2")
    [[ -n $f ]] || { echo "ralph-operator: no transcript names $2 ($1): no ledger row" >&2; exit 0; }
    "$HERE/usage-session.sh" operator ops "$(run_get RUN_ID)" --root "$(run_get KIT_DIR)" --session "$(basename "$f" .jsonl)" \
      && echo "LEDGERED=$1" >>"$OP_RUN"
  ) 9>>"$OP_DIR/ledger.lock"
}
# ledger_all — every operator of this run that has ended and has no row yet
ledger_all() {
  local s u
  while IFS=$'\t' read -r s u; do
    [[ -n $s ]] && ! sess_exact "$s" && ledger "$s" "$u"
  done < <(paste <(sed -n 's/^SESSION=//p' "$OP_RUN" 2>/dev/null) <(sed -n 's/^URL=//p' "$OP_RUN" 2>/dev/null))
  return 0
}

# deny_rules <kit> — the operator's launch line. Edit rules bind every
# file-editing tool and the shell's rm, mv, sed -i and redirects on the path
# (probed on 2.1.288 under allowManagedPermissionRulesOnly; README).
deny_rules() {
  local r
  {
    for r in "$ROOT" "$(cd "$ROOT" && pwd -P)"; do echo "Edit(/$r/**)"; done
    echo "Edit(/$1/.claude/**)"
    for r in "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json"; do echo "Edit(/$r)"; done
  } | awk '!seen[$0]++'
}

cmd_kick() {
  op_active || refuse "this checkout has no operator run — start one with: $HERE/ralph-operator.sh start"
  refuse_retired
  [[ -e $STOP_FILE ]] && refuse "ralph/STOP is present — the owner's; it is not the operator's to remove"
  sess_live "$RALPH_SENTINEL_SESSION" && refuse "the sentinel ($RALPH_SENTINEL_SESSION) is running; under an operator it must not be"
  reconcile
  runner_live && refuse "the runner is already running ($RALPH_TMUX_SESSION)"
  sess_live "$RALPH_ITER_SESSION" && refuse "an iteration session ($RALPH_ITER_SESSION) is live with no runner — a human must say whose it is"
  load_stop
  local how=first
  if [[ -n $STOP_LINE ]]; then
    [[ -n $KIND ]] || refuse "stop #$STOP_LINE is not classified — classify it first"
    [[ -n $NOTED ]] || refuse "stop #$STOP_LINE has no incident note — post it first"
    case $KIND in
      loop-right) [[ -n $RELEASED ]] || refuse "stop #$STOP_LINE is loop-right: the loop stays stopped until the owner runs '$HERE/ralph-operator.sh release'" ;;
      transient)
        (($(relaunches_left) > 0)) || refuse "the relaunch budget ($MAX_RELAUNCHES per 24 h, shared with the heartbeat's quota relaunches) is spent"
        date +%s >>"$RELAUNCH_LOG" ;;
      broken)
        [[ $(kit_tree) != "$KIT_AT" ]] || refuse "stop #$STOP_LINE is broken and the kit on origin's default branch has not changed since — install the fix first" ;;
    esac
    how="stop=$STOP_LINE kind=$KIND"
  fi
  tmux new-session -d -s "$RALPH_TMUX_SESSION" -c "$ROOT" "$(printf '%q' "$HERE/ralph-operator.sh") _runner" \
    || refuse "tmux could not start $RALPH_TMUX_SESSION"
  op_event kick "$how"
  echo "kicked: $RALPH_TMUX_SESSION ($how)"
  nudge kick
}

# _runner — what `kick` runs inside the runner's tmux session: the heartbeat,
# its output kept, and its exit code recorded for the operator.
cmd__runner() {
  local args rc
  args=$(run_get ARGS)
  eval "set -- $args"
  "$HERE/ralph-heartbeat.sh" "$@" 2>&1 | tee -a "$OP_DIR/runner.log"
  rc=${PIPESTATUS[0]}
  op_event runner-exit "rc=$rc — $(grep -v '^[[:space:]]*$' "$OP_DIR/runner.log" | tail -1)"
}

rotate_report() {
  echo "WAKE=rotate (your context is past RALPH_OPERATOR_CTX_CAP)"
  summary
  echo "NEXT=hand off: $HERE/ralph-operator.sh handoff \"<the state, and anything in flight>\" — then end your turn"
}

cmd_wait() {
  op_active || refuse "this checkout has no operator run"
  refuse_retired
  exec 8>"$OP_DIR/wait.lock"
  flock -n 8 || refuse "another wait is already running for this run"
  local cursor total batch wake me
  me=$(caller_session) || true
  # The cap is read where the operator would otherwise wait or take a wake: its
  # context grows only by its own turns. A wake held back is the successor's.
  if over_cap; then rotate_report; return 4; fi
  while :; do
    retired "$me" && refuse "operator $me was retired while it waited; the run's operator is $(op_session)"
    reconcile # and WAS_LIVE: liveness as it was before the journal is read below
    cursor=$(cat "$OP_DIR/cursor" 2>/dev/null || echo 0)
    total=$(wc -l <"$OP_EVENTS" 2>/dev/null || echo 0)
    # Only a stop wakes it. A merge or a notice while the runner runs is "nothing
    # to do", and reading it would cost a turn that re-reads the whole context,
    # every iteration: they wait in the journal for the next stop's report.
    if ((total > cursor)) && tail -n +"$((cursor + 1))" "$OP_EVENTS" | cut -f2 | grep -qxE 'runner-exit|runner-gone'; then
      if over_cap; then rotate_report; return 4; fi
      sleep "$SETTLE" # what follows a wake joins this report
      reconcile
      total=$(wc -l <"$OP_EVENTS")
      batch=$(sed -n "$((cursor + 1)),${total}p" "$OP_EVENTS")
      echo "$total" >"$OP_DIR/cursor"
      wake=$(cut -f2 <<<"$batch" | grep -xE 'runner-exit|runner-gone' | sort -u | paste -sd, -)
      echo "WAKE=$wake"
      summary
      echo "EVENTS"
      cut -f1-3 <<<"$batch" | cut -c1-400 | sed 's/^/  /'
      report_tail
      return 0
    fi
    # WAS_LIVE, not a fresh check: a runner that journals its exit and goes away
    # after the read above would be "not running; nothing unread" here, and the
    # next wait would report that same stop as new.
    if [[ -z $WAS_LIVE ]]; then
      echo "$total" >"$OP_DIR/cursor"
      echo "WAKE=none (the runner is not running; nothing unread)"
      summary
      next_step
      return 3
    fi
    sleep "$POLL"
  done
}

report_tail() {
  echo "RUNNER_LOG (last 6 lines of .ralph/operator/runner.log)"
  tail -n 6 "$OP_DIR/runner.log" 2>/dev/null | cut -c1-300 | sed 's/^/  /'
  echo "NEWEST_LOGS=$(ls -t "$ROOT/.ralph/logs" 2>/dev/null | grep -v '^operator-' | head -4 | paste -sd' ' -)"
  next_step
}

cmd_classify() {
  local kind=${1-} evidence must kit="" was=""
  shift || true
  evidence="$*"
  case $kind in transient|broken|loop-right) ;; *) usage ;; esac
  [[ -n ${evidence// /} ]] || refuse "the classification needs its evidence"
  op_active || refuse "this checkout has no operator run"
  refuse_retired
  reconcile
  load_stop
  [[ -n $STOP_LINE ]] || refuse "there is no stop to classify"
  # One classification per stop, with one change allowed: to loop-right, until
  # the note. It is the safe direction (the owner decides), and without it an
  # operator that said broken and then found no kit bug could post no note (a
  # broken note needs --pr), so no successor and no way out. The earlier kind
  # stays in the journal and in the note's Kind line (was=).
  if [[ -n $KIND ]]; then
    [[ -z $NOTED ]] || refuse "stop #$STOP_LINE already has its incident note — its classification ($KIND) is final"
    [[ $KIND != loop-right ]] || refuse "stop #$STOP_LINE is already classified loop-right — one classification per stop"
    [[ $kind == loop-right ]] || refuse "stop #$STOP_LINE is already classified $KIND — a classification changes only to loop-right, before the note"
    was=" was=$KIND"
  fi
  must=$(owners_stop)
  [[ -z $must || $kind == loop-right ]] || refuse "stop #$STOP_LINE can only be loop-right: $must"
  [[ $kind == broken ]] && kit=" kit=$(kit_tree)"
  op_event classify "kind=$kind$kit$was — $evidence"
  if [[ -n $was ]]; then echo "stop #$STOP_LINE reclassified $KIND -> $kind"; else echo "stop #$STOP_LINE classified $kind"; fi
}

# note — the incident's one note, and the end of its operator: the next operator
# is started first, so the note can name the link that handles the next stop.
cmd_note() {
  local pr="" did msg delivered=no prev purl n url="" next rc why
  [[ ${1-} == --pr ]] && { pr="${2-}"; [[ -n $pr ]] || usage; shift 2; }
  did="$*"
  [[ -n ${did// /} ]] || usage
  op_active || refuse "this checkout has no operator run"
  refuse_retired
  load_stop
  [[ -n $STOP_LINE ]] || refuse "there is no stop to note"
  [[ -n $KIND ]] || refuse "stop #$STOP_LINE is not classified — the classification comes first"
  [[ -z $NOTED ]] || refuse "stop #$STOP_LINE already has its incident note — one per stop"
  [[ $KIND != broken || -n $pr ]] || refuse "a broken stop's note names the kit PR that repairs it (--pr)"
  # Recorded before the successor starts: what it reads first must hold the note.
  op_event note "pr=${pr:-none} — $did"
  prev=$(op_session); purl=$(run_get URL); n=$(($(op_count) + 1))
  url=$(spawn "$n" "after its incident note on stop #$STOP_LINE" 2>"$OP_DIR/spawn.err"); rc=$?
  why=$(sed 's/^ralph-operator: REFUSED — //' "$OP_DIR/spawn.err" | tail -1)
  case $rc in
    0) next=$url ;;
    2) url=""; next="none: $why. The stop waits for the owner"; op_event budget "$why" ;;
    *) url=""; next="none: operator #$n did not start ($why); the run's link stays $purl" ;;
  esac
  msg="Stop: $STOP_TEXT (driver: $(driver_exit))
Kind: $(ev_text "$(ev_last classify "$STOP_LINE")" | sed 's/ kit=[0-9a-f]*//')
Did: $did
PR: ${pr:-none}
Next operator: $next"
  RALPH_NOTIFY_KIND=note "$HERE/notify.sh" -t "$RALPH_NOTIFY_TITLE operator" "$msg" >/dev/null 2>&1 && delivered=yes
  op_event posted "delivered=$delivered next=${url:-none}"
  echo "stop #$STOP_LINE noted (delivered: $delivered)"
  [[ $delivered == yes ]] || { keep_undelivered "note for stop #$STOP_LINE" "$msg"; echo "ralph-operator: the note was recorded but notify.sh could not post it; it is kept for 'repost'" >&2; }
  if ((rc == 2)); then
    retire "$prev" "$purl" # a spent budget ends this operator all the same
    echo "NEXT_OPERATOR=$next"
    echo "You are retired: end your turn now. No operator follows until the owner starts one."
  elif [[ -z $url ]]; then
    echo "NEXT_OPERATOR=$next"
    echo "No successor started, so you remain the operator: carry on with what status says."
  else
    retire "$prev" "$purl"
    echo "NEXT_OPERATOR=$url ($(op_session))"
    echo "You are retired: end your turn now. Operator #$n takes the run from here."
  fi
}

# handoff — what ROTATE asks for: the next operator, from the record and this note.
cmd_handoff() {
  local what="$*" prev purl n url rc why msg
  [[ -n ${what// /} ]] || usage
  op_active || refuse "this checkout has no operator run"
  refuse_retired
  prev=$(op_session); purl=$(run_get URL); n=$(($(op_count) + 1))
  op_event handoff "operator #$((n - 1)), at $(op_context) tokens of context: $what"
  url=$(spawn "$n" "with a handoff: its context passed RALPH_OPERATOR_CTX_CAP ($CTX_CAP)" 2>"$OP_DIR/spawn.err"); rc=$?
  why=$(sed 's/^ralph-operator: REFUSED — //' "$OP_DIR/spawn.err" | tail -1)
  if ((rc == 2)); then
    op_event budget "$why"
    msg="ralph: run $(run_get RUN_ID): $why. Operator #$((n - 1)) reached its context cap and is retired; none follows until you start one. The runner carries on, and its stops reach you directly."
    "$HERE/notify.sh" "$msg" >/dev/null 2>&1 || keep_undelivered "no operator follows (budget spent)" "$msg"
    retire "$prev" "$purl"
    echo "You are retired: end your turn now. No operator follows ($why)."
    return 0
  fi
  ((rc == 0)) || refuse "operator #$n did not start ($why), so you remain the operator"
  local delivered=no
  msg="ralph: run $(run_get RUN_ID) has a new operator (#$n; #$((n - 1)) reached its context cap) — the run's link is now: $url"
  RALPH_NOTIFY_KIND=info "$HERE/notify.sh" "$msg" >/dev/null 2>&1 && delivered=yes
  op_event posted "delivered=$delivered handoff next=$url"
  [[ $delivered == yes ]] || { keep_undelivered "new link after a handoff" "$msg"; echo "ralph-operator: notify.sh could not post the new link; it is kept for 'repost'" >&2; }
  retire "$prev" "$purl"
  echo "NEXT_OPERATOR=$url ($(op_session))"
  echo "You are retired: end your turn now. Operator #$n takes the run from here."
}

cmd_link() {
  op_active || refuse "this checkout has no operator run"
  run_get URL
  op_live || { echo "ralph-operator: its session ($(op_session)) is not running" >&2; return 1; }
}

# repost — send what notify.sh could not, as one note, and clear it. Any
# operator may run it: the message is the owner's, not the sender's.
cmd_repost() {
  op_active || refuse "this checkout has no operator run"
  refuse_retired
  [[ -s $UNDELIVERED ]] || refuse "nothing undelivered"
  RALPH_NOTIFY_KIND=note "$HERE/notify.sh" -t "$RALPH_NOTIFY_TITLE operator" "$(cat "$UNDELIVERED")" >/dev/null 2>&1 \
    || refuse "notify.sh could not post the $(undelivered_count) kept message(s); they are kept"
  op_event posted "delivered=yes repost of $(undelivered_count) message(s)"
  rm -f "$UNDELIVERED"
  echo "reposted"
}

cmd_release() {
  op_active || refuse "this checkout has no operator run"
  refuse_retired
  load_stop
  [[ $KIND == loop-right ]] || refuse "release is for a loop-right stop; the latest stop is ${KIND:-unclassified}"
  op_event release "the owner released stop #$STOP_LINE"
  echo "stop #$STOP_LINE released"
  nudge release
}

cmd_status() {
  op_active || { echo "OPERATOR=none"; return 0; }
  echo "RUN_ID=$(run_get RUN_ID) OPERATOR=#$(op_count) SESSION=$(op_session) ($(op_live && echo live || echo gone))"
  echo "URL=$(run_get URL)"
  reconcile
  summary
  if ((BUDGET > 0)); then echo "BUDGET=$(op_spent)/$BUDGET (24 h, weighted)"; else echo "BUDGET=$(op_spent)/none"; fi
  echo "KIT=$(kit_state)"
  echo "LAST_EVENTS"
  tail -n 5 "$OP_EVENTS" 2>/dev/null | cut -f1-3 | cut -c1-300 | sed 's/^/  /'
  next_step
}

cmd=${1-}; shift || true
case $cmd in
  start) cmd_start "$@" ;;
  kick) cmd_kick ;;
  wait) cmd_wait ;;
  classify) cmd_classify "$@" ;;
  note) cmd_note "$@" ;;
  handoff) cmd_handoff "$@" ;;
  release) cmd_release ;;
  repost) cmd_repost ;;
  link) cmd_link ;;
  status) cmd_status ;;
  _runner) cmd__runner ;;
  _retire) cmd__retire "$@" ;;
  *) usage ;;
esac
