# Lessons behind the loop's rules — cold storage

**Not on the hot path.** `ralph/PROMPT.md` keeps each rule and the number that justifies it; the story of
how the rule was learned lives here, keyed by section, and an iteration reads a lesson only when it is
about to break the rule it backs. Nothing in this file is deleted; new lessons are appended under the
rule they explain. (Moved out of `PROMPT.md` on 2026-09-21 — the README ("Hot path"): the prompt is re-sent on every
turn of an iteration, ~300 times, so a paragraph here costs 300 paragraphs there.)

## §1 — Read one spec, not all of `specs/`

Re-reading 20+ unrelated specs costs ~15K tokens of a usage window that is shared with the review
gates (PROGRESS.md 2026-07-24). The status table is the index; the front (`scripts/ralph-iterate.sh`) picks from it and the session reads only the target
spec plus its `Depends-on`. Older iteration-log history lives in `PROGRESS-archive.md` — read it only when
investigating something specific.

## §2 — Slice for half a window; fewest slices that fit

The four gates, their fix rounds, the confirm pass, CI and the merge reliably consume around half the
per-iteration ceiling on their own — CI alone has run 14 minutes. A slice that reaches `checkpoint(green)`
late dies in its gates and is resumed, costing a whole extra iteration: on 2026-09-03 spec 17 slice 6
spanned two iterations, the second killed 258 s after its CI went green. The floor still binds: each slice
pays the same fixed tail, so nine micro-slices are nine mostly-overhead iterations.

Slicing is no longer the implementer's: `scripts/ralph-iterate.sh` has a review-tier session slice each
spec once and writes `ralph/slices-<spec>.md`, which the owner may edit and the loop then follows
(`docs/coordinator-split.md`, decision 4). The session that builds a slice does not decide its size.

## §3 — Delegation

`docs/delegation-ledger.md` derives a size floor per task type once enough rows exist; until then treat
everything on the eligible list as eligible — the guess is what is being measured. `scripts/agy-task.sh`
exits 75 when agy itself is unavailable (dispatch timeout, quota, auth refusal); that is not a task
failure — do the task inline and record the fallback in the ledger, so the ledger shows when delegation
stopped paying.

## §4 — Red edits files; the coordinator observes red and commits

A headless session has nobody to approve a prompt, so it can write only what its launch grants. `PROMPT.md`
used to launch red with no grant at all. One project's first implementer added `--permission-mode
acceptEdits` on its own and red wrote its files; the next two followed the prompt to the letter, every
write was refused, and the implementer copied red's files out of its transcript by hand — until the
permission classifier, correctly, refused that as working around a denial and a supervised run stopped
(2026-10-03). The grant now lives in `claude-run.sh`, by stage: red gets file edits, the adversary gets
file edits held to test files, every other stage gets nothing, and a caller's own permission flag is
refused, so the scope cannot depend on what one implementer thought to pass. The adversary is held to
tests because one that can edit the implementation can fix what it was sent to expose, and the finding
never reaches you.

Neither gets the toolchain or git, on purpose: running the suite is running code the session just wrote,
on a box that holds the loop's credentials. So "observe it fail" and `checkpoint(red)` belonged to
the implementer at first, and since `docs/coordinator-split.md` phase 1 belong to
`scripts/ralph-iterate.sh`: the session that wants the merge no longer picks the spec, launches red,
decides that red is red, or reads the plan review's verdict. The script does, from exit codes and a
`VERDICT:` line, and stops with the reason when a step fails. The client refuses red's writes to the protected paths (a deny rule each); exit 3 means
one moved anyway — the rule stopped holding. `claude-run.sh` reverts nothing, because it cannot tell
red's write from its caller's; `ralph-iterate.sh` is the caller, knows nothing else is editing, reverts
the listed paths and re-runs red once. Twice in a row is not noise: it stops.

## §5 — Gates one at a time; markers; the confirm cap

**Sequential gates.** Firing all three gates at once drained the shared window mid-iteration and lost
the whole iteration's work (PROGRESS.md 2026-07-24). Sequential costs wall-clock and buys the iteration
actually finishing; a gate that fails to run is not a gate.

**Independent review.** A gate's value is the context it does *not* have — so reading gates never run in
the implementing session, even though the implementer tier is now Opus 5 too. If Fable is unavailable:
adversarial review via parallel sub-agents on Opus 5 at `xhigh` (finder → refuting verifiers,
single-round; PROGRESS 2026-07-19 precedent) — never skip the axis.

**Markers.** A gate's verdict lives only in the session that ran it, so a limit death during gate 3
re-spends gates 1 and 2 — the resume table knows only `green`. `gate-marker.sh record` writes an empty
commit naming the tree it vouches for and refuses on a dirty tree (exit 3): the gate reviewed the working
tree, so while fixes are uncommitted HEAD is not what it read. `check` is exact tree-sha equality; marker
*presence* authorises nothing; every ambiguous state resolves to "run it" — doubt costs tokens, never
coverage. Any tree change invalidates every marker, including a rebase picking up an unrelated commit —
correct, since the code under review genuinely changed. Never hand-write or hand-read a marker:
`scripts/test-gate-marker.sh` pins the exact-match property, and improvised inline git is precisely how
it gets lost. A marker is recorded *after* fixes, so it vouches for a tree one step newer than the gate
literally read; the confirm pass covers that delta.

**The confirm pass** exists for reading findings (`/security-review`, spec-fidelity) whose fix is itself
an unverified reading claim, and for regressions a fix introduces that no gate ever saw. Re-running the
full pipeline is unaffordable. **At most two confirm rounds per slice**: the loop has no other bound —
each round's fixes are themselves unreviewed, so a session that keeps finding fault with its own work
re-enters the loop forever and spends the whole usage window without merging (2026-07-30: ten rounds on
spec 06 slice 4d, two consecutive 2h ceiling deaths, nothing landed). Rounds are cheap only relative to
the full pipeline — three of them cost more than the slice is worth.

**Bookkeeping is enforced, not trusted.** `assert-complete` decides from git state alone — never from
gate output or from what a session believes it did. If it refuses, it names what is missing; fix the gap,
do not work around it.

## §6 — PR first, then PROGRESS.md; the real number once

PROGRESS.md is written after `checkpoint(gated)`, so a SECOND write to it moves the tree past step 5's
`confirm` marker and `scripts/merge-pr.sh` refuses on a docs-only delta — paid for by spec 10 slice 1,
spec 12 slice 3 and spec 13 slice 5, and avoided by spec 10 slice 2, which ordered the PR first. An
inline `curl POST .../pulls` is denied by the auto-mode classifier, which is why `open-pr.sh` exists;
called twice on the same branch it returns the PR that is already open, so a resumed iteration records
the same number. A guessed number is indistinguishable from a recorded fact once committed, and a killed
iteration leaves it on the branch as a false claim that the slice merged (2026-07-30: slice 4d committed
"done, #61" while the highest PR was #60; the iteration died at the ceiling before ever opening one).

The `**Delegation**:` marker is the ledger's missing denominator: it records dispatches *and*
opportunities passed on. `scripts/delegation-audit.sh` greps for the exact marker, deliberately distinct
from the words "delegated"/"skipped" in ordinary prose.

**The status is a machine-read field: `in-progress (slice K/M)`, nothing else.** The front takes the next
slice from it, and a status it could not parse used to be read as slice 1. In claude_sandbox (PR #18,
2026-10-12) the session wrote `in-progress (slice 1 of 2)`, following the prose legend under the
project's own table, which predates the template's. The front read slice 1, found the merged
`ralph/03-progress-table-s1` still on origin, resumed it and stopped on a rebase conflict with its own
squash (stop #67). `progress-sync.sh` now refuses any other in-progress spelling before the merge, and
the front stops on one instead of guessing.

## §7 — One commit on main

The squash-merge collapses checkpoints into one conventional commit. `gh` is not on the devbox;
`merge-pr.sh`'s REST call is permission-allowlisted and inline merge calls get denied by the auto-mode
classifier — see "Devbox git/PR mechanics" in `ralph/ITERATION-ZERO.md`. Call the script as a **bare
command**: allow rules match every part of a compound line, so `cd … && scripts/merge-pr.sh` falls through to
the classifier, which denied it in a consuming project on 2026-09-27; bare, it merged.

**A merged branch is dead.** In a consuming project on 2026-09-22 a session merged a PR, kept working and
pushed two more commits to the same branch name. Origin had deleted the branch at merge, so the push
recreated it; nobody opened a second PR; locally the branch looked like in-progress work, because a
squash-merge never makes a branch an ancestor of `main`. Five days later `main` contradicted decisions the
owner had approved, and the loss was found only because the owner remembered and asked. The failure is
silent — no gate sees a commit on a branch nobody watches — so the rule is procedural (step 7) and
`preflight.sh` warns when a local branch's upstream is gone (`preflight-lib.sh`, tested). The first version
of that warning used `grep` inside a `set -e` assignment and killed preflight on every healthy tree; the
check now lives in a sourced library precisely so a test can hold it.

## Loop driver

The previous `ralph-loop` plugin kept one ever-growing session — retired 2026-07-21 after measuring
101.5M cache-read vs 0.7M output tokens over 546 turns (see PROGRESS-archive.md). Iteration completion
is judged by git state (`origin/main` advancing), never screen text: the pane is scraped only for the
completion promise, the remote-control URL (posted to the notifications issue at each iteration start,
or, under a standing operator, to the operator's journal: the owner's one link is the operator's) and the usage-limit banner.

**Quota deaths are not failures.** The driver classifies a no-merge exit by grepping the pane snapshot
for the limit banner. A *merit* exit counts toward the 2-strike no-progress breaker and stops the loop
(exit 1); a *limit* exit counts for nothing and yields to the supervisor (exit 2), which probes
`claude -p --model claude-opus-5` every 10 minutes and relaunches the driver once the pool answers — at
most 3 relaunches per rolling 24h, then it stops and notifies. The probe is a real request because no CLI or
API surface exposes Max pool status headlessly (`/usage` is TUI-only). Exit codes are a contract between
the two scripts; see the header of `scripts/ralph-driver.sh`.

**Budget the usage window.** Iterations get progressively shorter as the shared 5-hour window drains —
the driver's iterations, every headless gate, and any interactive session all draw on it. That is why
step 1 reads one spec, the front slices once per spec, and step 5 runs the gates one at a time.

## Hot path (the README ("Hot path"))

Anything read at the start of an iteration is re-sent on every subsequent turn, so its cost is size ×
turn count. In a measured project (median 320 turns per iteration) one status table that had grown to
98K tokens accounted for an estimated 7–26% of the whole project's spend, re-read 320 times to answer
"which task is next?". Padding alone was 52% of it. Hence the per-section budgets in each hot file's
header and `scripts/hot-path-check.sh`.

**Check budgets where the file is written, not only where it is read.** Preflight is the reader's check:
it runs at the start of the next iteration, after the PROGRESS.md that broke the budget is already on
main, so it can only stop the loop. Step 6 writes the log after the suite and the gates have run, so
`scripts/merge-pr.sh` also runs `hot-path-check.sh` for `ralph/*` branches, and an over-budget log entry
is refused while the PR is still open, so the worker trims it, pushes and merges again (PROMPT.md step 7) instead of the loop halting (claude_sandbox PR #18, 2026-10-12: a 32-line entry
merged and the next preflight refused).
