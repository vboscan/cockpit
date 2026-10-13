#!/usr/bin/env bash
# ANCHOR: ralph-park-wip — move an interrupted iteration's uncommitted residue
# onto a wip/ branch and leave the working tree clean.
#
#   scripts/park-wip.sh [label]
#
# Why this exists: scripts/preflight.sh refuses to start an iteration on a dirty
# tree (leftovers would ride into the next spec's commit), but a usage-limit
# death dirties the tree *by construction* — the session is killed mid-edit. So
# the supervisor's recovery path would wait out the pool, relaunch, and trip
# preflight on the wreckage of the very iteration it was recovering from
# (observed 2026-07-25 01:15). This script is what makes that recovery land.
#
# What it does NOT touch: committed work. `checkpoint(red|green|gate:*|gated)`
# commits on the iteration branch are the coherent states the next iteration
# resumes from (ralph/PROMPT.md step 2) — only the sub-checkpoint residue is
# parked, and it is parked rather than discarded because a limit death leaves
# real work behind (PROGRESS.md 2026-07-24).
#
# Exit 0 whether or not there was anything to park, so callers can invoke it
# unconditionally.
#
# Constraint: parking reverts modified tracked files to HEAD, so the loop's own
# scripts must be committed before the loop runs — an uncommitted edit to this
# file would be reverted underneath the shell executing it (same hazard as the
# merge-first rule in PROGRESS.md 2026-07-22). preflight.sh's clean-tree check
# already guarantees this at iteration start.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

LABEL="${1:-park}"

if [[ -z "$(git status --porcelain)" ]]; then
  echo "park-wip: tree already clean — nothing to park"
  exit 0
fi

# Remember where to return. A detached HEAD has no branch name, so fall back to
# the revision — and switching back to a raw sha needs an explicit --detach
# (`git switch <sha>` hard-fails with "a branch is expected"), which under
# `set -e` would abort mid-park and strand the loop on the wip branch.
origin_ref="$(git branch --show-current)"
if [[ -n $origin_ref ]]; then
  switch_back=(git switch -q "$origin_ref")
else
  origin_ref="$(git rev-parse HEAD)"
  switch_back=(git switch -q --detach "$origin_ref")
fi

stamp="$(date +%Y%m%dT%H%M%S)"
wip="wip/${LABEL}-${stamp}"

# Creating a branch carries the dirty tree with it, so the residue is committed
# on the wip branch and the original branch is left clean once we switch back.
git switch -q -c "$wip"
git add -A
git commit -q -m "wip(${LABEL}): residue parked from ${origin_ref} at ${stamp}

Uncommitted work from an iteration that did not reach a checkpoint.
Parked by scripts/park-wip.sh so the next iteration starts on a clean tree.
Nothing here has passed the gates; treat it as a salvage source, not as work."
"${switch_back[@]}"

echo "park-wip: parked residue on ${wip} (returned to ${origin_ref}, tree clean)"
