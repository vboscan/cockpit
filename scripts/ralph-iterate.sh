#!/usr/bin/env bash
# ANCHOR: ralph-iterate — the coordinator for the front of an iteration
# (docs/coordinator-split.md, phase 1). A script, not a session: it wants
# nothing, so it has no reason to route around a step that fails.
#
#   scripts/ralph-iterate.sh front [--attended] [--spec NN] [--allow-empty-red]
#
# What it owns, in order:
#   preflight   scripts/preflight.sh
#   select      the target spec, from PROGRESS.md's Gates and status table
#   branch      resume the spec's branch from its newest checkpoint, or branch
#               off the default branch
#   slice       a review-tier session, once per spec -> ralph/slices-<spec>.md
#   red         a red-tier session writes tests, stubs and the plan; THIS script
#               observes red and commits checkpoint(red)
#   plan-review a review-tier session; its last line is the verdict
# What it hands over: .ralph/handoff and a PROMPT line for the implementer
# session, which starts at step 4 of ralph/PROMPT.md.
#
#   --attended         a human is watching. Required for a supervised spec and
#                      to pass an unticked "spec NN manual-validated" gate.
#                      The driver never passes it.
#   --spec NN          run this spec instead of the lowest-numbered one
#                      (attended only; a blocked spec is still refused).
#   --allow-empty-red  accept a red that leaves the suite green — a spec whose
#                      criteria are all recorded manual steps (attended only).
#
# EXIT CODE CONTRACT — scripts/ralph-driver.sh branches on these:
#   0   the front is done; .ralph/handoff says where the implementer starts
#   1   merit stop: a human must look (preflight, red or the plan review failed)
#   2   usage limit: quota, not merit — the supervisor waits and relaunches
#   10  every spec is done
#   11  a clean stop for the owner: an owner gate, a supervised spec with nobody
#       watching, or nothing unblocked. Not a strike against the breaker.
#   64  usage error
# Every non-zero exit but 64 is notified (scripts/notify.sh) with the reason.
#
# Selection rules, pinned here because a script cannot interpret prose:
#   - A row is skipped when its status is `done` or `in-progress (slice M/M)`
#     (merged, waiting to be archived in step 6).
#   - A row is blocked when its status is `blocked`, its Design-blocked cell
#     starts with `yes`, a spec in its Depends-on cell is not done, or an
#     unticked gate names it in `(blocks NN, …)`.
#   - An unticked `spec NN manual-validated` gate whose spec is done stops an
#     unattended run: supervised specs are validated before the loop runs alone.
#   - A row whose Notes contain `supervised` runs only with --attended.
set -uo pipefail

# Everything below is ONE compound command, so bash reads this file to its last
# line before running any of it. The front switches and rebases branches, and a
# branch that predates a kit upgrade carries an older copy of this very script:
# read line by line, the shell would be executing a file rewritten underneath it
# (the same hazard park-wip.sh documents for uncommitted edits).
{
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ralph-config.sh
. "$HERE/ralph-config.sh"
# shellcheck source=scripts/pane-busy.sh
. "$HERE/pane-busy.sh" # pane_limited
ROOT="$RALPH_REPO_ROOT"
LOGS="$ROOT/.ralph/logs"
HANDOFF="$ROOT/.ralph/handoff"
RED_TIMEOUT="${RALPH_RED_TIMEOUT:-1800}"
REVIEW_TIMEOUT="${RALPH_REVIEW_TIMEOUT:-900}"
COMPILE_CMD="${RALPH_TEST_COMPILE_CMD:-${RALPH_TYPECHECK_CMD:-}}"

EXIT_OK=0 EXIT_MERIT=1 EXIT_LIMIT=2 EXIT_ALL_DONE=10 EXIT_OWNER=11 EXIT_USAGE=64

usage() { echo "usage: $(basename "$0") front [--attended] [--spec NN] [--allow-empty-red]" >&2; exit $EXIT_USAGE; }
[[ "${1-}" == front ]] || usage
shift
attended="${RALPH_ATTENDED:-0}"; want_spec=""; allow_empty_red=0
while (($#)); do
  case "$1" in
    --attended) attended=1 ;;
    --spec) want_spec="${2-}"; [[ "$want_spec" =~ ^[0-9][0-9]$ ]] || usage; shift ;;
    --allow-empty-red) allow_empty_red=1 ;;
    *) usage ;;
  esac
  shift
done
if [[ "$attended" != 1 && ( -n "$want_spec" || "$allow_empty_red" == 1 ) ]]; then
  echo "ralph-iterate: --spec and --allow-empty-red are the owner's — they need --attended" >&2; exit $EXIT_USAGE
fi

say() { echo "ralph-iterate: $*"; }
# stop <code> <reason> — the one way out on anything but success: the reason
# goes to stderr and to the owner, so a stop is never silent.
stop() {
  echo "ralph-iterate: STOP ($1) — $2" >&2
  "$HERE/notify.sh" "ralph front stopped (exit $1): $2" >/dev/null 2>&1 || true
  exit "$1"
}
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
g() { git -C "$ROOT" "$@"; }

cd "$ROOT" || exit $EXIT_MERIT
mkdir -p "$LOGS"
rm -f "$HANDOFF"

# --- preflight ----------------------------------------------------------
"$HERE/preflight.sh" || stop $EXIT_MERIT "preflight failed — see its output"

# --- select -------------------------------------------------------------
progress="$ROOT/PROGRESS.md"; archive="$ROOT/PROGRESS-archive.md"
[[ -f "$progress" ]] || stop $EXIT_MERIT "no PROGRESS.md"
section() { awk -v h="$1" '$0 ~ "^## "h {f=1; next} /^## / {f=0} f' "$2"; }
gates="$(section "Gates" "$progress")"
open_gates="$(grep -E '^- \[ \] ' <<<"$gates" || true)"

if grep -qE '^- \[ \] iteration-zero' <<<"$gates"; then
  {
    echo "RESUME=iteration-zero"
    echo "PROMPT=Run one iteration per ralph/PROMPT.md: iteration zero has not passed — run ralph/ITERATION-ZERO.md."
  } > "$HANDOFF"
  say "iteration zero has not passed"; cat "$HANDOFF"; exit $EXIT_OK
fi

done_specs=" "
if [[ -f "$archive" ]]; then
  while IFS='|' read -r _ spec _; do spec="$(trim "$spec")"; [[ "$spec" =~ ^[0-9][0-9]- ]] && done_specs+="${spec:0:2} "; done \
    < <(section "Done specs" "$archive" | grep -E '^\| [0-9][0-9]-' || true)
fi
gate_blocked=" $(grep -oE '\(blocks [^)]*\)' <<<"$open_gates" | grep -oE '[0-9]{2}' | tr '\n' ' ')"
unvalidated="$(grep -oE 'spec [0-9]{2} manual-validated' <<<"$open_gates" | grep -oE '[0-9]{2}' | tr '\n' ' ')"

rows="$(section "Spec status" "$progress" | grep -E '^\| [0-9][0-9]-' | sort -t'|' -k2,2 || true)"
# A spec whose last slice is merged counts as done before step 6 archives it.
while IFS='|' read -r _ spec status _; do
  spec="$(trim "$spec")"; status="$(trim "$status")"
  # The status names the last merged slice, and only as `(slice K/M)`. Anything
  # else read as slice 1 would resume a merged branch (LESSONS §6): refuse it.
  if [[ "$status" == in-progress* ]] && ! { [[ "$status" =~ ^in-progress\ \(slice\ ([0-9]+)/([0-9]+)\) ]] \
       && ((10#${BASH_REMATCH[1]} >= 1 && 10#${BASH_REMATCH[1]} <= 10#${BASH_REMATCH[2]})); }; then
    stop $EXIT_OWNER "PROGRESS.md row $spec has '$status' — an in-progress status is 'in-progress (slice K/M)', 1 ≤ K ≤ M, K the last merged slice; fix the row"
  fi
  if [[ "$status" == done* ]]; then done_specs+="${spec:0:2} "
  elif [[ "$status" =~ ^in-progress\ \(slice\ ([0-9]+)/([0-9]+)\) && "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then done_specs+="${spec:0:2} "; fi
done <<<"$rows"

if [[ "$attended" != 1 ]]; then
  for nn in $unvalidated; do
    [[ "$done_specs" == *" $nn "* ]] && stop $EXIT_OWNER "owner gate: 'spec $nn manual-validated' is unticked — the loop does not run unattended past a supervised spec until its owner validates it"
  done
fi

SPEC=""; STATUS=""; NOTES=""; reasons=""; pending=0
while IFS='|' read -r _ spec status depends design notes _; do
  spec="$(trim "$spec")"; status="$(trim "$status")"; depends="$(trim "$depends")"; design="$(trim "$design")"; notes="$(trim "$notes")"
  [[ -n "$spec" ]] || continue
  nn="${spec:0:2}"
  [[ "$done_specs" == *" $nn "* ]] && continue
  pending=$((pending + 1))
  why=""
  [[ "$status" == blocked* ]] && why="status is blocked"
  [[ -z "$why" && "$design" == yes* ]] && why="design-blocked"
  if [[ -z "$why" ]]; then
    for dep in $(grep -oE '[0-9]{2}' <<<"$depends" || true); do
      [[ "$done_specs" == *" $dep "* ]] || { why="depends on $dep, not done"; break; }
    done
  fi
  [[ -z "$why" && "$gate_blocked" == *" $nn "* ]] && why="blocked by an unticked owner gate"
  if [[ -n "$want_spec" ]]; then
    [[ "$nn" == "$want_spec" ]] || continue
    [[ -z "$why" ]] || stop $EXIT_OWNER "spec $spec was asked for and is blocked: $why"
  fi
  if [[ -n "$why" ]]; then reasons+="$spec: $why; "; continue; fi
  SPEC="$spec"; STATUS="$status"; NOTES="$notes"; break
done <<<"$rows"

if [[ -z "$SPEC" ]]; then
  [[ -n "$want_spec" ]] && stop $EXIT_OWNER "spec $want_spec is not an open row in PROGRESS.md"
  ((pending == 0)) && { say "every spec is done"; exit $EXIT_ALL_DONE; }
  stop $EXIT_OWNER "nothing is unblocked — ${reasons%; }"
fi
NN="${SPEC:0:2}"
SPEC_FILE="specs/$SPEC.md"
[[ -f "$ROOT/$SPEC_FILE" ]] || stop $EXIT_MERIT "PROGRESS.md names $SPEC and $SPEC_FILE does not exist"
if [[ "$NOTES" == *supervised* && "$attended" != 1 ]]; then
  stop $EXIT_OWNER "spec $SPEC is supervised and nobody is watching — run it with: scripts/ralph-iterate.sh front --attended"
fi

K=1
[[ "$STATUS" =~ ^in-progress\ \(slice\ ([0-9]+)/([0-9]+)\) ]] && K=$((BASH_REMATCH[1] + 1))
SLICES_FILE="ralph/slices-$SPEC.md"
say "target: $SPEC, slice $K"

# --- workers --------------------------------------------------------------
# worker <stage> <timeout> <log> <model> <prompt> — one headless session
# through claude-run.sh. Returns its exit code; a usage-limit banner in what it
# printed ends the front with the limit code, whatever the worker's own code.
worker() {
  local stage="$1" tmo="$2" log="$3" model="$4" prompt="$5" rc
  timeout "$tmo" "$HERE/claude-run.sh" "$stage" "$NN" "$K" -- -p --model "$model" "$prompt" >"$log" 2>"$log.err"; rc=$?
  if pane_limited "$(cat "$log" "$log.err" 2>/dev/null)"; then stop $EXIT_LIMIT "usage limit during $stage for $SPEC"; fi
  return $rc
}
slice_count() { grep -cE '^[0-9]+\. ' "$1" 2>/dev/null || true; }
slice_title() { grep -E "^$2\. " "$1" 2>/dev/null | head -1 | sed -E 's/^[0-9]+\. //'; }
default_ref() {
  local d; d="$(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
  g rev-parse --verify --quiet "$d" >/dev/null || d="${d#origin/}"
  printf '%s' "$d"
}
suite_green() { [[ -n "${RALPH_TEST_CMD:-}" ]] && (cd "$ROOT" && eval "$RALPH_TEST_CMD") >"$LOGS/suite.out" 2>&1; }
# fresh_base — stand on the local default branch at origin's tip ("fresh main").
fresh_base() {
  local local_default="${BASE#origin/}"
  g switch -q "$local_default" 2>/dev/null || stop $EXIT_MERIT "cannot switch to $local_default"
  [[ "$BASE" == "$local_default" ]] || g merge -q --ff-only "$BASE" >/dev/null 2>&1 \
    || stop $EXIT_MERIT "local $local_default does not fast-forward to $BASE — a human must look"
}

# --- branch: resume, or start ------------------------------------------------
g fetch -q origin 2>/dev/null || true
BASE="$(default_ref)"
branch=""; resume=""
for cand in "ralph/$SPEC-s$K" "ralph/$SPEC"; do
  [[ "$cand" == "ralph/$SPEC" && "$K" != 1 ]] && continue
  if ! g rev-parse --verify --quiet "refs/heads/$cand" >/dev/null; then
    # The spec's state lives on its branch, and the branch may exist only on
    # origin (a fresh clone, a box that lost its checkout): resume it from there.
    # Starting clean under its name would rebuild work that already has a PR.
    g rev-parse --verify --quiet "refs/remotes/origin/$cand" >/dev/null || continue
    g branch -q --track "$cand" "origin/$cand" || stop $EXIT_MERIT "cannot track origin/$cand"
  fi
  # A local branch whose upstream is gone is a merged branch (LESSONS §7).
  if g branch -vv | grep -qE "^[* ] +$cand +[0-9a-f]+ \[[^]]*: gone\]"; then
    stop $EXIT_MERIT "local branch $cand is dead (its upstream is gone) — delete it; nothing resumes from a merged branch"
  fi
  branch="$cand"; break
done

if [[ -n "$branch" ]]; then
  g switch -q "$branch" || stop $EXIT_MERIT "cannot switch to $branch"
  if ! g rebase -q "$BASE" >"$LOGS/rebase.out" 2>&1; then
    g rebase --abort >/dev/null 2>&1 || true
    stop $EXIT_MERIT "$branch does not rebase onto $BASE — see .ralph/logs/rebase.out"
  fi
  newest="$(g log --format=%s "$BASE..HEAD" | grep -m1 -oE '^checkpoint\((red|plan|slices|green|gated|gate:[^)]*)\)' || true)"
  case "$newest" in
    "checkpoint(gated)") resume=gated ;;
    "checkpoint(green)"|"checkpoint(gate:"*) resume=green ;;
    "checkpoint(plan)") resume=red ;;
    "checkpoint(red)") resume=review ;;
    "checkpoint(slices)") resume=start ;;
    "") [[ -z "$(g log --format=%h "$BASE..HEAD")" ]] || stop $EXIT_MERIT "$branch has commits and no checkpoint — a human must say what they are"
        resume=start ;;
  esac
  if [[ "$resume" == green || "$resume" == gated ]] && ! suite_green; then
    # A pushed branch is shared state (a PR, its reviews, a PROGRESS record):
    # never parked and rebuilt under the same name — that duplicates the work
    # and can never push. A human says what it is.
    g rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null \
      && stop $EXIT_MERIT "checkpoint($resume) on $branch fails the suite after rebasing onto $BASE (see .ralph/logs/suite.out), and origin has $branch — fix it there or delete it; nothing starts clean over a pushed branch"
    parked="wip/${branch#ralph/}-$(date +%Y%m%dT%H%M%S)"
    g branch -m "$branch" "$parked"
    say "checkpoint($resume) on $branch fails the suite after rebasing — parked as $parked, starting clean"
    branch=""; resume=""
  else
    say "resuming $branch at ${newest:-its branch point}"
  fi
fi

if [[ -z "$branch" ]]; then fresh_base; resume=start; fi

# The tree under scripts/ may have just changed (a rebase onto a kit upgrade, or
# the switch to the default branch). Take the config's defaults again from the
# version now on disk: `:=` keeps every value already set and adds what is new.
# shellcheck source=scripts/ralph-config.sh
. "$HERE/ralph-config.sh"

# --- slice: once per spec ------------------------------------------------------
if [[ ! -f "$ROOT/$SLICES_FILE" ]]; then
  [[ "$K" == 1 ]] || stop $EXIT_OWNER "$SPEC is at slice $K and $SLICES_FILE does not exist — write it from the slice plan in PROGRESS.md"
  log="$LOGS/slice-$SPEC.txt"
  worker slice "$REVIEW_TIMEOUT" "$log" "$RALPH_REVIEW_MODEL" "Slice $SPEC_FILE for the Ralph loop. The build of a slice must fit half an iteration: the gates, fix rounds, CI and the merge take the other half. Use the fewest slices that individually fit; each must be independently mergeable and gated and leave the default branch releasable. Reply with only a numbered list, one line per slice: 'N. <title> — <the acceptance criteria and deliverables it covers>'. If the whole spec fits, reply with one line." \
    || stop $EXIT_MERIT "the slice session failed for $SPEC — see .ralph/logs/slice-$SPEC.txt"
  (( $(slice_count "$log") > 0 )) || stop $EXIT_MERIT "the slice session returned no numbered slice for $SPEC — see .ralph/logs/slice-$SPEC.txt"
  new_slices="$(printf '# Slices — %s\n\nWritten by a review-tier session (scripts/ralph-iterate.sh). The owner may edit this file; the loop\nreads the numbered lines.\n\n%s\n' "$SPEC" "$(grep -E '^[0-9]+\. ' "$log")")"
else
  new_slices=""
fi
if [[ -n "$new_slices" ]]; then M="$(grep -cE '^[0-9]+\. ' <<<"$new_slices")"; else M="$(slice_count "$ROOT/$SLICES_FILE")"; fi
(( M >= K )) || stop $EXIT_MERIT "$SLICES_FILE has $M slice(s) and PROGRESS.md says slice $K is next"

if [[ -z "$branch" ]]; then
  if (( M == 1 )); then branch="ralph/$SPEC"; else branch="ralph/$SPEC-s$K"; fi
  g rev-parse --verify --quiet "refs/heads/$branch" >/dev/null && stop $EXIT_MERIT "branch $branch already exists — a human must say what it is"
  g switch -q -c "$branch" || stop $EXIT_MERIT "cannot create $branch"
fi
if [[ -n "$new_slices" ]]; then
  mkdir -p "$ROOT/ralph"; printf '%s\n' "$new_slices" > "$ROOT/$SLICES_FILE"
  g add -- "$SLICES_FILE" && g commit -q -m "checkpoint(slices): $SPEC — $M slice(s)" \
    || stop $EXIT_MERIT "cannot commit $SLICES_FILE"
fi
TITLE="$(slice_title "$ROOT/$SLICES_FILE" "$K")"
PLAN="ralph/plan-$SPEC-$K.md"

# --- red: written by a worker, observed and committed here ---------------------
# run_red <feedback-file|""> — one red session. A protected-path exit (3) is
# reverted and re-run once: this script is the caller, nothing else is editing
# the tree, so the write is the session's.
run_red() {
  local fb="$1" log prompt rc try
  prompt="/tdd red $SPEC_FILE $K — slice $K/$M: $TITLE. Write the failing acceptance tests, compile-only stubs and $PLAN. You cannot run the toolchain or git; the coordinator observes red and commits."
  [[ -n "$fb" ]] && prompt+=" This is a revision: read $fb first and fix what it names."
  for try in 1 2; do
    log="$LOGS/red-$SPEC-$K.txt"
    RALPH_RED_PROTECTED="${RALPH_RED_PROTECTED-} $SLICES_FILE" worker red "$RED_TIMEOUT" "$log" "$RALPH_RED_MODEL" "$prompt"; rc=$?
    case $rc in
      0) return 0 ;;
      3) while IFS= read -r p; do
           p="$(trim "$p")"; [[ -n "$p" && "$p" != /* && "$p" != *..* ]] || continue # repo-relative only
           if g cat-file -e "HEAD:$p" 2>/dev/null; then g checkout -q HEAD -- "$p"; else rm -f -- "$ROOT/$p"; fi
         done < <(grep -E '^  ' "$log.err" || true)
         say "red changed a protected path — reverted (attempt $try)" ;;
      *) stop $EXIT_MERIT "the red session failed for $SPEC slice $K (exit $rc) — see .ralph/logs/red-$SPEC-$K.txt" ;;
    esac
  done
  stop $EXIT_MERIT "red changed a protected path twice for $SPEC slice $K — see .ralph/logs/red-$SPEC-$K.txt.err"
}
# observe_red — sets RED_DEFECT and returns 1 when what red left is not red.
observe_red() {
  RED_DEFECT=""
  [[ -n "$(g status --porcelain)" ]] || { RED_DEFECT="red wrote nothing"; return 1; }
  [[ -f "$ROOT/$PLAN" ]] || { RED_DEFECT="red wrote no plan: $PLAN is missing"; return 1; }
  if [[ -n "$COMPILE_CMD" ]] && ! (cd "$ROOT" && eval "$COMPILE_CMD") >"$LOGS/red-compile.out" 2>&1; then
    RED_DEFECT="the tree does not compile after red (\`$COMPILE_CMD\`): $(tail -5 "$LOGS/red-compile.out")"; return 1
  fi
  [[ -n "${RALPH_TEST_CMD:-}" ]] || stop $EXIT_MERIT "RALPH_TEST_CMD is unset — there is no suite to observe red with"
  RED_SUITE="suite red (\`$RALPH_TEST_CMD\`)"
  if suite_green; then
    [[ "$allow_empty_red" == 1 ]] || { RED_DEFECT="no test fails after red (\`$RALPH_TEST_CMD\` is green)"; return 1; }
    RED_SUITE="suite green, accepted by the owner (--allow-empty-red)"
  fi
  return 0
}
# red_round <feedback-file|""> <label> — red, observed, committed. One retry
# when what red left is not red; then a human looks.
red_round() {
  local fb="$1" label="$2" defect_file="$LOGS/red-defect-$SPEC-$K.txt"
  run_red "$fb"
  if ! observe_red; then
    say "not red: $RED_DEFECT — one retry"
    printf 'The coordinator did not accept the red you left.\n\n%s\n' "$RED_DEFECT" > "$defect_file"
    run_red ".ralph/logs/$(basename "$defect_file")"
    observe_red || stop $EXIT_MERIT "red is not red after a retry for $SPEC slice $K: $RED_DEFECT"
  fi
  g add -A && g commit -q -m "checkpoint(red): $SPEC $K/$M$label" \
    -m "Written by a fresh $RALPH_RED_MODEL session (claude-run.sh red). Observed by ralph-iterate.sh: ${COMPILE_CMD:+compile green (\`$COMPILE_CMD\`), }$RED_SUITE." \
    || stop $EXIT_MERIT "cannot commit checkpoint(red)"
}

# --- plan review: the last line is the verdict -------------------------------
# plan_review <n> — returns 0 on pass, 1 on revise; anything else stops.
plan_review() {
  local log="$LOGS/plan-review-$SPEC-$K-$1.txt" verdict
  worker plan-review "$REVIEW_TIMEOUT" "$log" "$RALPH_REVIEW_MODEL" "Review $PLAN and the checkpoint(red) tests against $SPEC_FILE (slice $K/$M: $TITLE): does every criterion in the slice map to a test with concrete inputs and outputs, does the plan add nothing beyond the spec, does the build fit half a usage window? Report only issues that would cause wrong behaviour, a missing test or scope creep. End with exactly one line: 'VERDICT: pass' or 'VERDICT: revise'." \
    || stop $EXIT_MERIT "the plan review failed for $SPEC slice $K — see .ralph/logs/$(basename "$log")"
  verdict="$(grep -oiE 'VERDICT: *(pass|revise)' "$log" | tail -1 | tr '[:upper:]' '[:lower:]' | sed -E 's/verdict: *//')"
  case "$verdict" in
    pass) return 0 ;;
    revise) return 1 ;;
    *) stop $EXIT_MERIT "the plan review gave no verdict for $SPEC slice $K — see .ralph/logs/$(basename "$log")" ;;
  esac
}

if [[ "$resume" == start ]]; then red_round "" ""; resume=review; fi
if [[ "$resume" == review ]]; then
  round=0
  until plan_review $((round + 1)); do
    round=$((round + 1))
    (( round <= 2 )) || stop $EXIT_MERIT "the plan review asked for a third revision of $SPEC slice $K — escalated to the owner; see .ralph/logs/plan-review-$SPEC-$K-$round.txt"
    say "plan review: revise (round $round)"
    red_round ".ralph/logs/plan-review-$SPEC-$K-$round.txt" " (revision $round)"
  done
  g commit -q --allow-empty -m "checkpoint(plan): $SPEC $K/$M — pass" || stop $EXIT_MERIT "cannot record the plan review"
  resume=red
fi

# --- hand over ----------------------------------------------------------------
{
  echo "SPEC=$SPEC"
  echo "SPEC_FILE=$SPEC_FILE"
  echo "SLICE=$K"
  echo "SLICES=$M"
  echo "BRANCH=$branch"
  echo "RESUME=$resume"
  echo "PLAN=$PLAN"
  echo "PROMPT=Run one iteration per ralph/PROMPT.md: spec $SPEC, slice $K/$M, branch $branch, resume at checkpoint($resume). The front is done."
} > "$HANDOFF"
say "front done"
cat "$HANDOFF"
exit $EXIT_OK
}
