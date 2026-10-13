#!/usr/bin/env bash
# Behavioural tests for ralph-iterate.sh (the coordinator for the front of an
# iteration). No network and no model: `claude` is a stub on PATH that plays
# the slice, red and plan-review sessions from a script, and every fixture is a
# real git repository with a bare origin.
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0; root="$(mktemp -d)"; trap 'rm -rf "${root}"' EXIT
stub="${root}/stub"; mkdir -p "${root}/bin"
ok()  { pass=$((pass+1)); echo "  ok  — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; echo "         $2"; }

# --- stub claude -------------------------------------------------------------
# Plays a stage by the prompt it is given. Red runs $STUB/red.<n>.sh for its
# n-th call when present, else the default: one test file, a failing suite, the
# plan. Reviews print $STUB/review.<n>.out, else a pass.
cat > "${root}/bin/claude" <<'STUBEOF'
#!/usr/bin/env bash
args="$*"; printf '%s\n' "${args}" >> "${STUB}/argv"
bump() { local n; n=$(( $(cat "${STUB}/$1.n" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${STUB}/$1.n"; echo "${n}"; }
text="ok"; rc=0
case "${args}" in
  *"/tdd red"*)
    n="$(bump red)"; plan="$(grep -oE 'ralph/plan-[^ ]+\.md' <<<"${args}" | head -1)"
    if [[ -f "${STUB}/red.${n}.sh" ]]; then . "${STUB}/red.${n}.sh"
    else mkdir -p pkg ralph; echo "case ${n}" >> pkg/thing_test.go; : > FAILING; echo "plan" > "${plan}"; fi
    text="red written" ;;
  *"Slice specs/"*) bump slice >/dev/null; text="$(cat "${STUB}/slice.out" 2>/dev/null || echo '1. the whole spec — every criterion')" ;;
  *"Review ralph/plan"*) n="$(bump review)"; text="$(cat "${STUB}/review.${n}.out" 2>/dev/null || printf 'Looks right.\nVERDICT: pass')" ;;
esac
[[ -f "${STUB}/limit" ]] && text="You've hit your weekly limit · resets 3pm"
python3 -c 'import json,sys; print(json.dumps({"type":"result","is_error":False,"result":sys.argv[1],"session_id":"s","usage":{},"total_cost_usd":0}))' "${text}"
exit "${rc}"
STUBEOF
chmod +x "${root}/bin/claude"

# --- fixture -----------------------------------------------------------------
# mk <name>: a project with the kit's scripts, built from $GATES, $ROWS, $DONE.
GATES='- [x] iteration-zero: PASSED'
DONE=''
mk() {
  P="${root}/$1"; local o="${root}/$1.git" spec
  rm -rf "${stub}"; mkdir -p "${stub}"
  git init -q --bare -b main "${o}"; git init -q -b main "${P}"
  ( cd "${P}" && git config user.email t@x && git config user.name t && git remote add origin "${o}"
    mkdir -p scripts specs ralph .ralph
    cp "${KIT_SCRIPTS}"/{ralph-iterate,ralph-config,pane-busy,claude-run,usage-lib,operator-lib,token-sentinel}.sh scripts/
    printf '#!/usr/bin/env bash\n[[ ! -e "${STUB}/preflight-fail" ]]\n' > scripts/preflight.sh
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "${STUB}/notify"\n' > scripts/notify.sh
    chmod +x scripts/*.sh
    printf '.ralph/config.sh\n.ralph/logs/\n.ralph/handoff\n' > .gitignore
    cat > .ralph/config.sh <<'CFG'
: "${RALPH_PROJECT_NAME:=fixture}"
: "${RALPH_TEST_CMD:=test ! -e FAILING}"
: "${RALPH_TEST_COMPILE_CMD:=test ! -e BROKEN}"
: "${RALPH_RED_MODEL:=red-model}"
: "${RALPH_REVIEW_MODEL:=review-model}"
CFG
    printf '# PROGRESS\n\n## Gates\n\n%s\n\n## Spec status\n\n| Spec | Status | Depends-on | Design-blocked | Notes |\n|-|-|-|-|-|\n%s\n\n## Log\n' "${GATES}" "${ROWS}" > PROGRESS.md
    printf '# archive\n\n## Done specs\n\n| Spec | Merged PRs | Done on |\n|-|-|-|\n%s\n\n## Older log entries\n' "${DONE}" > PROGRESS-archive.md
    while IFS='|' read -r _ spec _; do spec="$(echo "${spec}" | xargs)"; [[ -n "${spec}" ]] && echo "# ${spec}" > "specs/${spec}.md"; done <<<"${ROWS}"
    git add -A && git commit -q -m init && git push -q -u origin main && git remote set-head origin main >/dev/null ) || echo "fixture $1 failed" >&2
}
# it [args…]: run the front in the current fixture; exit code in $st
it() { ( cd "${P}" && STUB="${stub}" RALPH_USAGE_LEDGER="${root}/ledger.jsonl" PATH="${root}/bin:${PATH}" bash scripts/ralph-iterate.sh front "$@" >"${root}/out" 2>"${root}/err" ); st=$?; }
ho() { sed -n "s/^$1=//p" "${P}/.ralph/handoff" 2>/dev/null; }
calls() { grep -c -- "$1" "${stub}/argv" 2>/dev/null || true; }
subjects() { git -C "${P}" log --format=%s main..HEAD; }
why() { echo "exit ${st}; err: $(tail -3 "${root}/err"); out: $(tail -3 "${root}/out")"; }

echo "select"
ROWS='| 03-extract | blocked | 01 | no | |
| 04-contract | not-started | 01 | no | |
| 05-adapter | not-started | 03, 04 | no | |'
DONE='| 01-scaffold | #1 | 2026-01-01 |'
mk sel1; it
[[ $st -eq 0 && "$(ho SPEC)" == 04-contract ]] && ok "skips a blocked row and picks the lowest-numbered open spec" || bad "select lowest" "$(why)"

ROWS='| 05-adapter | not-started | 01 | no | |
| 19-fork | not-started | 01 | no | |
| 04-contract | not-started | 09 | no | |
| 06-ui | not-started | 01 | yes | |
| 07-relay | not-started | 01 | no | |'
GATES='- [x] iteration-zero: PASSED
- [ ] thresholds set (blocks 05, 17)'
mk sel2; it
[[ $st -eq 0 && "$(ho SPEC)" == 07-relay ]] && ok "unmet Depends-on, Design-blocked: yes and a '(blocks NN)' gate each block; order is by number, not by row" || bad "blocked kinds" "$(why) / $(ho SPEC)"
GATES='- [x] iteration-zero: PASSED'

ROWS='| 02-infra | in-progress (slice 2/2) | 01 | no | |
| 03-next | not-started | 02 | no | |'
mk sel3; it
[[ $st -eq 0 && "$(ho SPEC)" == 03-next ]] && ok "a row whose last slice is merged counts as done, for selection and for Depends-on" || bad "merged-not-archived" "$(why)"

ROWS=''; mk sel4; it
[[ $st -eq 10 && "$(calls .)" -eq 0 ]] && ok "no open row: exit 10 (every spec is done), no session started" || bad "all done" "$(why)"

ROWS='| 05-adapter | not-started | 03 | no | |
| 06-ui | blocked | 01 | no | |'
mk sel5; it
[[ $st -eq 11 ]] && grep -q "05-adapter: depends on 03" "${stub}/notify" && grep -q "06-ui: status is blocked" "${stub}/notify" && ok "nothing unblocked: exit 11, the owner is told why per spec" || bad "all blocked" "$(why) / $(cat "${stub}/notify" 2>/dev/null)"

ROWS='| 03-extract | not-started | 01 | no | supervised |'
mk sel6; it
[[ $st -eq 11 && "$(calls .)" -eq 0 ]] && grep -q "supervised" "${stub}/notify" && ok "a supervised spec with nobody watching: exit 11" || bad "supervised unattended" "$(why)"
it --attended
[[ $st -eq 0 && "$(ho SPEC)" == 03-extract ]] && ok "the same spec runs with --attended" || bad "supervised attended" "$(why)"

ROWS='| 04-contract | not-started | 01 | no | |'
GATES='- [x] iteration-zero: PASSED
- [ ] spec 01 manual-validated
- [ ] spec 04 manual-validated'
mk sel7; it
[[ $st -eq 11 ]] && grep -q "spec 01 manual-validated" "${stub}/notify" && ok "an unticked manual-validated gate on a done spec stops an unattended run" || bad "validation gate" "$(why)"
it --attended
[[ $st -eq 0 ]] && ok "and does not stop an attended one; the gate on a spec not yet done blocks nothing" || bad "validation gate attended" "$(why)"

GATES='- [ ] iteration-zero: PASSED `<date>`'
mk sel8; it
[[ $st -eq 0 && "$(ho RESUME)" == iteration-zero && "$(calls .)" -eq 0 ]] && grep -q "ITERATION-ZERO" <<<"$(ho PROMPT)" && ok "iteration zero not passed: the hand-off sends the session to it, no worker runs" || bad "iteration zero" "$(why)"
GATES='- [x] iteration-zero: PASSED'

ROWS='| 04-contract | not-started | 01 | no | |
| 19-fork | not-started | 01 | no | |
| 20-later | not-started | 04 | no | |'
mk sel9; it --spec 19
[[ $st -eq 64 ]] && ok "--spec is the owner's: refused without --attended" || bad "--spec unattended" "$(why)"
it --attended --spec 19
[[ $st -eq 0 && "$(ho SPEC)" == 19-fork ]] && ok "--attended --spec NN runs that spec ahead of a lower-numbered one" || bad "--spec" "$(why)"
mk sel9b; it --attended --spec 20
[[ $st -eq 11 ]] && grep -q "depends on 04" "${stub}/notify" && ok "--spec does not unblock a blocked spec" || bad "--spec blocked" "$(why)"

mk pre; : > "${stub}/preflight-fail"; it
[[ $st -eq 1 && "$(calls .)" -eq 0 ]] && ok "preflight failing: exit 1 before any session" || bad "preflight" "$(why)"

echo "front"
ROWS='| 04-contract | not-started | 01 | no | |'
mk f1; it
want='checkpoint(plan): 04-contract 1/1 — pass
checkpoint(red): 04-contract 1/1
checkpoint(slices): 04-contract — 1 slice(s)'
[[ $st -eq 0 && "$(subjects)" == "${want}" ]] && ok "a fresh spec: slices, red and plan checkpoints, in that order" || bad "fresh checkpoints" "$(why) / $(subjects)"
[[ "$(git -C "${P}" branch --show-current)" == ralph/04-contract && "$(ho BRANCH)" == ralph/04-contract && "$(ho RESUME)" == red && "$(ho SLICE)/$(ho SLICES)" == 1/1 ]] && ok "the hand-off names the branch, slice 1/1 and resume at red" || bad "hand-off" "$(cat "${P}/.ralph/handoff" 2>&1)"
[[ "$(ho PROMPT)" == "Run one iteration per ralph/PROMPT.md: spec 04-contract, slice 1/1, branch ralph/04-contract, resume at checkpoint(red)."* ]] && ok "the PROMPT line starts with the text the driver checks for" || bad "prompt line" "$(ho PROMPT)"
[[ "$(calls 'Slice specs/')" -eq 1 && "$(calls '/tdd red')" -eq 1 && "$(calls 'Review ralph/plan')" -eq 1 ]] && ok "one slice, one red and one plan-review session" || bad "session count" "$(cat "${stub}/argv")"
grep '/tdd red' "${stub}/argv" | grep -q -- '--permission-mode acceptEdits' && ! grep 'Review ralph/plan' "${stub}/argv" | grep -q -- '--permission-mode' && ok "red is launched with its write grant, the reviewer with none (claude-run.sh)" || bad "grants" "$(cat "${stub}/argv")"
grep '/tdd red' "${stub}/argv" | grep -q "ralph/slices-04-contract.md)" && ok "the slice plan is a protected path for red" || bad "slices protected" "$(grep '/tdd red' "${stub}/argv" | cut -c1-300)"
git -C "${P}" show --stat --format=%b HEAD~1 | grep -q "Observed by ralph-iterate.sh: compile green" && [[ -z "$(git -C "${P}" status --porcelain)" ]] && ok "checkpoint(red) records what the script observed; the tree is clean" || bad "red commit" "$(git -C "${P}" show --stat --format=%b HEAD~1 | head -5)"

mk f1b; sed -i '/RALPH_RED_MODEL/d' "${P}/.ralph/config.sh"; it
[[ $st -eq 0 ]] && grep '/tdd red' "${stub}/argv" | grep -q -- '--model review-model' && ok "a config with no RALPH_RED_MODEL: red runs on the review tier" || bad "red model default" "$(why)"

mk f2; printf ':\n' > "${stub}/red.1.sh"; printf ':\n' > "${stub}/red.2.sh"; it
[[ $st -eq 1 && "$(calls '/tdd red')" -eq 2 ]] && grep -q "red wrote nothing" "${stub}/notify" && ok "red writing nothing: one retry, then exit 1" || bad "empty red" "$(why)"

mk f3; printf 'mkdir -p pkg ralph; echo t >> pkg/thing_test.go; echo plan > "${plan}"\n' > "${stub}/red.1.sh"; cp "${stub}/red.1.sh" "${stub}/red.2.sh"; it
[[ $st -eq 1 ]] && grep -q "no test fails after red" "${stub}/notify" && ok "a suite still green after red is not red: exit 1" || bad "green red" "$(why)"
grep -q "read .ralph/logs/red-defect-04-contract-1.txt" "${stub}/argv" && grep -q "no test fails" "${P}/.ralph/logs/red-defect-04-contract-1.txt" && ok "the retry is told why, in a file it can read" || bad "red feedback" "$(tail -1 "${stub}/argv" | cut -c1-200)"
mk f3b; printf 'mkdir -p pkg ralph; echo t >> pkg/thing_test.go; echo plan > "${plan}"\n' > "${stub}/red.1.sh"; it --attended --allow-empty-red
[[ $st -eq 0 ]] && git -C "${P}" log -1 --format=%b HEAD~1 | grep -q "accepted by the owner" && ok "--attended --allow-empty-red accepts it and the commit says so" || bad "allow empty red" "$(why)"

mk f4; printf 'mkdir -p pkg ralph; echo t >> pkg/thing_test.go; : > FAILING; : > BROKEN; echo plan > "${plan}"\n' > "${stub}/red.1.sh"; printf 'rm -f BROKEN\n' > "${stub}/red.2.sh"; it
[[ $st -eq 0 && "$(calls '/tdd red')" -eq 2 ]] && ok "tests that do not compile are sent back once; a compiling retry is accepted" || bad "compile retry" "$(why)"

mk f5; printf 'mkdir -p pkg ralph; echo t >> pkg/thing_test.go; : > FAILING\n' > "${stub}/red.1.sh"; cp "${stub}/red.1.sh" "${stub}/red.2.sh"; it
[[ $st -eq 1 ]] && grep -q "red wrote no plan" "${stub}/notify" && ok "red without its plan file: exit 1" || bad "no plan" "$(why)"

mk f6; printf 'Criterion 2 has no test.\nVERDICT: revise\n' > "${stub}/review.1.out"; it
want='checkpoint(plan): 04-contract 1/1 — pass
checkpoint(red): 04-contract 1/1 (revision 1)
checkpoint(red): 04-contract 1/1
checkpoint(slices): 04-contract — 1 slice(s)'
[[ $st -eq 0 && "$(subjects)" == "${want}" ]] && ok "a revise verdict re-runs red and reviews again" || bad "revise" "$(why) / $(subjects)"
grep '/tdd red' "${stub}/argv" | tail -1 | grep -q "read .ralph/logs/plan-review-04-contract-1-1.txt" && ok "the revision is pointed at the review that asked for it" || bad "revise feedback" "$(grep '/tdd red' "${stub}/argv" | tail -1 | cut -c1-260)"

mk f7; for n in 1 2 3; do printf 'Still wrong.\nVERDICT: revise\n' > "${stub}/review.${n}.out"; done; it
[[ $st -eq 1 && "$(calls 'Review ralph/plan')" -eq 3 && "$(calls '/tdd red')" -eq 3 ]] && grep -q "third revision" "${stub}/notify" && ok "two revisions at most: the third revise verdict is exit 1, escalated" || bad "revise cap" "$(why)"

mk f8; printf 'It seems fine to me.\n' > "${stub}/review.1.out"; it
[[ $st -eq 1 ]] && grep -q "gave no verdict" "${stub}/notify" && ! subjects | grep -q "checkpoint(plan)" && ok "a review with no verdict line passes nothing: exit 1" || bad "no verdict" "$(why)"

mk f9; printf 'mkdir -p pkg ralph; echo t >> pkg/thing_test.go; : > FAILING; echo plan > "${plan}"; echo tampered >> specs/04-contract.md; echo new > specs/05-invented.md\n' > "${stub}/red.1.sh"; it
[[ $st -eq 0 && "$(calls '/tdd red')" -eq 2 ]] && [[ "$(cat "${P}/specs/04-contract.md")" == "# 04-contract" && ! -e "${P}/specs/05-invented.md" ]] && ok "red touching a protected path: reverted, re-run once, and nothing of it is committed" || bad "protected revert" "$(why) / $(cat "${P}/specs/04-contract.md")"
mk f9b; printf 'echo tampered >> specs/04-contract.md\n' > "${stub}/red.1.sh"; cp "${stub}/red.1.sh" "${stub}/red.2.sh"; it
[[ $st -eq 1 ]] && grep -q "protected path twice" "${stub}/notify" && ok "twice is not noise: exit 1" || bad "protected twice" "$(why)"

mk f10; : > "${stub}/limit"; it
[[ $st -eq 2 ]] && grep -q "usage limit" "${stub}/notify" && ok "a usage-limit banner from a worker: exit 2, the supervisor's code" || bad "limit" "$(why)"

printf '1. schema and Go codec — AC1, AC2\n2. TypeScript codec — AC3\n' > "${root}/two-slices"
mk f11; cp "${root}/two-slices" "${stub}/slice.out"; it
[[ $st -eq 0 && "$(ho BRANCH)" == ralph/04-contract-s1 && "$(ho SLICE)/$(ho SLICES)" == 1/2 ]] && grep '/tdd red' "${stub}/argv" | grep -q "slice 1/2: schema and Go codec" && ok "a two-slice plan: branch -s1, and red is given the slice's title" || bad "multi-slice" "$(why) / $(cat "${P}/.ralph/handoff" 2>&1)"

ROWS='| 04-contract | in-progress (slice 1/2) | 01 | no | |'
mk f12; ( cd "${P}" && { printf '# Slices\n\n'; cat "${root}/two-slices"; } > ralph/slices-04-contract.md && git add -A && git commit -q -m "slice 1 merged" && git push -q )
it
[[ $st -eq 0 && "$(ho BRANCH)" == ralph/04-contract-s2 && "$(ho SLICE)/$(ho SLICES)" == 2/2 && "$(calls 'Slice specs/')" -eq 0 ]] && grep '/tdd red' "${stub}/argv" | grep -q "specs/04-contract.md 2 " && ok "slice 2 of a sliced spec: no new slice session, red runs for slice 2 on -s2" || bad "next slice" "$(why) / $(cat "${P}/.ralph/handoff" 2>&1)"
mk f12b; it
[[ $st -eq 11 ]] && grep -q "slices-04-contract.md does not exist" "${stub}/notify" && ok "mid-spec with no slice file: exit 11, never a fresh slicing over merged work" || bad "missing slices file" "$(why)"
ROWS='| 04-contract | in-progress (slice 1 of 2) | 01 | no | |'
mk f12c; ( cd "${P}" && { printf '# Slices\n\n'; cat "${root}/two-slices"; } > ralph/slices-04-contract.md && git add -A && git commit -q -m "slice 1 merged" && git push -q \
  && git push -q origin main:refs/heads/ralph/04-contract-s1 )
it
[[ $st -eq 11 && "$(calls .)" -eq 0 && "$(git -C "${P}" branch --show-current)" == main ]] && grep -q "04-contract.*'in-progress (slice 1 of 2)'.*slice K/M" "${stub}/notify" && ok "an in-progress status not in the 'slice K/M' form: exit 11 naming the row, never read as slice 1 (stop #67)" || bad "malformed in-progress" "$(why) / $(cat "${stub}/notify" 2>&1)"
ROWS='| 04-contract | in-progress (slice 3/2) | 01 | no | |'
mk f12d; it
[[ $st -eq 11 && "$(calls .)" -eq 0 ]] && grep -q "'in-progress (slice 3/2)'" "${stub}/notify" && ok "a slice past the plan (K > M): exit 11, no session" || bad "K > M" "$(why)"

echo "resume"
ROWS='| 04-contract | not-started | 01 | no | |'
mk r1; it; rm -rf "${stub}"; mkdir -p "${stub}"; it
[[ $st -eq 0 && "$(calls .)" -eq 0 && "$(ho RESUME)" == red ]] && ok "a branch at checkpoint(plan): no session re-runs, hand-off resumes at red" || bad "resume plan" "$(why)"

mk r2; printf 'no verdict\n' > "${stub}/review.1.out"; it; rm -rf "${stub}"; mkdir -p "${stub}"; it
[[ $st -eq 0 && "$(calls '/tdd red')" -eq 0 && "$(calls 'Review ralph/plan')" -eq 1 && "$(ho RESUME)" == red ]] && ok "a branch at checkpoint(red): the plan review runs, red does not" || bad "resume red" "$(why)"

mk r3; it; ( cd "${P}" && rm -f FAILING && git add -A && git commit -q -m "checkpoint(green): 04-contract 1/1" ); rm -rf "${stub}"; mkdir -p "${stub}"; it
[[ $st -eq 0 && "$(calls .)" -eq 0 && "$(ho RESUME)" == green ]] && ok "a branch at checkpoint(green) with a green suite: hand-off resumes at green" || bad "resume green" "$(why)"
( cd "${P}" && git commit -q --allow-empty -m "checkpoint(gate:code-review) tree=abc: x" ); it
[[ $st -eq 0 && "$(ho RESUME)" == green ]] && ok "gate markers after green still resume at green" || bad "resume gate marker" "$(why)"

mk r4; it; ( cd "${P}" && git commit -q --allow-empty -m "checkpoint(green): 04-contract 1/1" ); rm -rf "${stub}"; mkdir -p "${stub}"; it
[[ $st -eq 0 && "$(ho RESUME)" == red && "$(calls '/tdd red')" -eq 1 ]] && git -C "${P}" branch | grep -q "wip/04-contract-" && ok "checkpoint(green) that fails the suite is parked on wip/ and the spec starts clean" || bad "park failing green" "$(why) / $(git -C "${P}" branch)"

# A branch cut before a kit upgrade carries the older scripts; the front starts on them.
mk r4b; ( cd "${P}" && sed -i '/RALPH_RED_MODEL/d' scripts/ralph-config.sh .ralph/config.sh && git add -A && git commit -q -m "older kit: no red-model default" && git push -q \
  && git switch -q -c ralph/04-contract && mkdir -p ralph && printf '# Slices\n\n1. the whole spec\n' > ralph/slices-04-contract.md && git add -A && git commit -q -m "checkpoint(slices): 04-contract — 1 slice(s)" \
  && git switch -q main && cp "${KIT_SCRIPTS}/ralph-config.sh" scripts/ && echo "# kit upgraded" >> scripts/ralph-iterate.sh && git add -A && git commit -q -m "kit upgrade" && git push -q && git switch -q ralph/04-contract )
it
[[ $st -eq 0 && "$(ho RESUME)" == red ]] && grep '/tdd red' "${stub}/argv" | grep -q -- '--model review-model' && ok "resuming a branch that predates a kit upgrade: rebased, and the upgraded config's defaults apply" || bad "stale kit on branch" "$(why)"

mk r5; ( cd "${P}" && git switch -q -c ralph/04-contract && echo x > stray && git add -A && git commit -q -m "some work" ); it
[[ $st -eq 1 ]] && grep -q "no checkpoint" "${stub}/notify" && ok "a spec branch with commits and no checkpoint: exit 1, a human says what they are" || bad "stray branch" "$(why)"

mk r6; ( cd "${P}" && git switch -q -c ralph/04-contract && git push -q -u origin ralph/04-contract && git push -q origin --delete ralph/04-contract && git fetch -q --prune && git switch -q main ); it
[[ $st -eq 1 ]] && grep -q "is dead" "${stub}/notify" && ok "a local branch whose upstream is gone is dead: exit 1, nothing resumes from it" || bad "dead branch" "$(why)"

# The spec's state lives on its branch, and the branch may exist only on origin:
# a fresh clone, a box that lost its checkout. The front resumes it from there.
mk r7; it; ( cd "${P}" && rm -f FAILING && git add -A && git commit -q -m "checkpoint(green): 04-contract 1/1" && git push -q -u origin ralph/04-contract && git switch -q main && git branch -q -D ralph/04-contract ); rm -rf "${stub}"; mkdir -p "${stub}"; it
[[ $st -eq 0 && "$(ho RESUME)" == green && "$(calls .)" -eq 0 ]] && git -C "${P}" branch -vv | grep -qE "^\* +ralph/04-contract .*\[origin/ralph/04-contract\]" && ok "a spec branch that exists only on origin is resumed from there, tracking it" || bad "remote-only branch" "$(why) / $(git -C "${P}" branch -vv)"

# A pushed branch is shared state (a PR, its reviews, a PROGRESS record): it is
# never parked and rebuilt under the same name. That would duplicate the work
# and could never push.
mk r8; it; ( cd "${P}" && git commit -q --allow-empty -m "checkpoint(green): 04-contract 1/1" && git push -q -u origin ralph/04-contract ); rm -rf "${stub}"; mkdir -p "${stub}"; it
[[ $st -eq 1 && "$(calls .)" -eq 0 ]] && grep -q "origin has ralph/04-contract" "${stub}/notify" && grep -q "suite.out" "${stub}/notify" && ! git -C "${P}" branch | grep -q "wip/" && [[ "$(git -C "${P}" branch --show-current)" == ralph/04-contract ]] && ok "checkpoint(green) that fails the suite on a pushed branch: exit 1, the branch stays as it is, nothing starts clean" || bad "pushed branch not parked" "$(why) / $(git -C "${P}" branch)"

echo "driver"
# The driver's side of the exit-code contract. Every path but a completed front
# ends before tmux is touched, so it can be held here with a stubbed front.
mk d1; cp "${KIT_SCRIPTS}/ralph-driver.sh" "${P}/scripts/"
printf '#!/usr/bin/env bash\necho "$*" >> "${STUB}/front"; [[ -n "${FRONT_PROMPT:-}" ]] && echo "PROMPT=${FRONT_PROMPT}" > "$(dirname "$0")/../.ralph/handoff"; exit "${FRONT_EXIT:-0}"\n' > "${P}/scripts/ralph-iterate.sh"
printf '#!/usr/bin/env bash\necho "$*" >> "${STUB}/session"; exit 1\n' > "${P}/scripts/claude-session.sh"; chmod +x "${P}"/scripts/*.sh
( cd "${P}" && git add -A && git commit -q -m "driver fixture" && git push -q )
drv() { ( cd "${P}" && env "$@" STUB="${stub}" PATH="${root}/bin:${PATH}" bash scripts/ralph-driver.sh -n 1 ${DRV_ARGS:-} >"${root}/out" 2>"${root}/err" ); st=$?; }
for pair in 10:0 11:0 2:2 1:1 7:1; do
  drv FRONT_EXIT="${pair%%:*}"
  [[ $st -eq "${pair##*:}" && ! -e "${stub}/session" ]] && ok "front exit ${pair%%:*} -> driver exit ${pair##*:}, no session spawned" || bad "driver maps ${pair}" "$(why)"
done
drv FRONT_EXIT=0
[[ $st -eq 1 && ! -e "${stub}/session" ]] && grep -q "left no hand-off" "${stub}/notify" && ok "a front that exits 0 with no hand-off spawns nothing" || bad "no hand-off" "$(why)"
drv FRONT_EXIT=0 FRONT_PROMPT="Run one iteration per ralph/PROMPT.md: spec 04-contract, slice 1/1."
[[ $st -eq 1 && -s "${stub}/session" ]] && ok "a completed front goes on to spawn the implementer session" || bad "spawn after front" "$(why)"
rm -f "${stub}/front" "${stub}/session"; DRV_ARGS="-p DESIGN_GATE_REACHED" drv FRONT_EXIT=11
[[ ! -e "${stub}/front" && -s "${stub}/session" ]] && ok "the design-gate phase has no front: preflight, then the session" || bad "design gate" "$(why)"

echo "  ${pass} passed, ${fail} failed"; [[ $fail -eq 0 ]]
