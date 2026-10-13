#!/usr/bin/env bash
# ANCHOR: ralph-preflight — step 0 of ralph/PROMPT.md and the post-image-upgrade
# check for the devbox. Hard-fails before any loop work runs gates-less.
set -euo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph-config.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0

err() { echo "preflight FAIL: $*" >&2; fail=1; }
# Warnings never set `fail`: they report on the loop's own bookkeeping, and a
# bookkeeping gap must not stop implementation work from running.
warn() { echo "preflight WARN: $*" >&2; }

# Repo-scoped skills every iteration depends on (ralph/PROMPT.md steps 3+5).
# Which ones is per-project ($RALPH_REQUIRED_SKILLS): `tdd` and
# `code-review-relative-to-specs` are what the protocol itself calls, and a
# project that adds others (frontend-design, agy-delegation) lists them there.
for skill in $RALPH_REQUIRED_SKILLS; do
  [[ -f "$REPO_ROOT/.claude/skills/$skill/SKILL.md" ]] || err "missing repo skill: .claude/skills/$skill/SKILL.md"
done

# Claude Code CLI
command -v claude >/dev/null 2>&1 || err "claude CLI not on PATH"

# Antigravity CLI — required only on the devbox (detected by hostname here;
# scripts/agy-task.sh uses the stricter $RALPH_DEVBOX_MARKER marker)
if [[ "$(hostname)" == "$RALPH_DEVBOX_HOSTNAME" ]]; then
  command -v agy >/dev/null 2>&1 || err "agy CLI not on PATH (devbox requires it for AGENTS.md rule 8 dispatch)"
fi

# The stack commands ralph/PROMPT.md step 4 runs. Warn-only: a project may
# genuinely have no typecheck step, and an unconfigured lint command must not
# stop implementation. But an iteration that silently runs NO suite is the
# failure this whole kit exists to prevent, so say so loudly.
if [[ -z "$RALPH_TEST_CMD" ]]; then
  warn "RALPH_TEST_CMD is unset in .ralph/config.sh — step 4 has no suite to run"
fi

# Step 5's gate bookkeeping must be executable. A missing gate-marker.sh fails
# safe on its own (no marker → the gate re-runs), but the real hazard is an
# iteration improvising inline git in its place: a hand-rolled check that greps
# for the gate name without comparing tree shas would authorise skipping a gate
# against code it never read. Hard-fail so nobody has to improvise.
for s in gate-marker.sh; do
  [[ -x "$REPO_ROOT/scripts/$s" ]] || err "missing or non-executable scripts/$s (ralph/PROMPT.md step 5)"
done

# The driver sources pane-busy.sh to know when an iteration has finished. If it
# is missing the driver dies at startup; if it silently reverts to a narrower
# check, healthy iterations waiting on gates read as idle and get killed
# (2026-07-26). Fail loud here rather than mid-run.
[[ -f "$REPO_ROOT/scripts/pane-busy.sh" ]] || err "missing scripts/pane-busy.sh (ralph-driver.sh sources it)"

# Loop state files must exist
for f in PROGRESS.md ralph/PROMPT.md AGENTS.md; do
  [[ -f "$REPO_ROOT/$f" ]] || err "missing $f"
done

# No `agy` may be mid-write when an iteration starts. An iteration killed by a
# usage limit can orphan its dispatch (the driver reaps what it can, but a
# SIGKILLed driver or a reboot cannot) — and an orphan keeps editing the tree
# the next iteration is about to branch from.
if pgrep -x agy >/dev/null 2>&1; then
  err "an agy process is still running — reap it before starting an iteration (pgrep -x agy)"
fi

# The tree must be clean. An iteration branches off fresh main; leftovers from
# a killed iteration would ride along into the next spec's commit. Park them
# (git switch -c wip/<what>) rather than discarding — a limit death leaves real
# work behind (PROGRESS.md 2026-07-24).
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
  err "working tree is dirty — park the leftovers on a wip/ branch before the next iteration"
fi

# A merged branch is dead (ralph/PROMPT.md step 7; LESSONS §7): origin deletes it
# at merge, so a local branch whose upstream is gone is almost always one whose
# PR landed, and a commit pushed to it recreates a branch nobody watches.
# Warn-only: the fix belongs to whoever left it, and an iteration never deletes
# branches it did not create. Tested by scripts/test-preflight-lib.sh.
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/preflight-lib.sh"
stale="$(stale_branches "$REPO_ROOT")"
if [[ -n "$stale" ]]; then
  warn "local branches whose upstream is gone (merged? delete them; never resume or push to them): $stale"
fi

# Never start from red. An iteration that begins on
# a failing suite cannot tell its own breakage from what it inherited, and the
# red→green checkpoints lose their meaning. Runs the configured suite only once
# the project's suite marker exists ($RALPH_SUITE_MARKER, e.g. package.json or
# go.mod); before that there is nothing to be red.
if [[ -n "$RALPH_TEST_CMD" && -e "$REPO_ROOT/${RALPH_SUITE_MARKER:-package.json}" ]]; then
  if ! (cd "$REPO_ROOT" && eval "$RALPH_TEST_CMD" >/dev/null 2>&1); then
    err "the suite is red on the current tree (\`$RALPH_TEST_CMD\`) — an iteration never starts from red; fix main first"
  fi
fi

# Hot-path budgets (README "Hot path"): the files read at the start
# of an iteration are re-sent on every turn, so unruled growth is a defect that
# compounds ~300× per iteration. Hard-fail: the fix is mechanical (archive rows
# and entries per PROGRESS.md's header) and belongs to a human, not an iteration.
if [[ -x "$REPO_ROOT/scripts/hot-path-check.sh" ]] && ! "$REPO_ROOT/scripts/hot-path-check.sh" >/dev/null; then
  err "hot-path files over budget — see scripts/hot-path-check.sh --print and PROGRESS.md's header"
fi

# Is the delegation denominator still being collected? (ralph/PROMPT.md step 6)
# Warn-only by design: the ledger going quiet is ambiguous — few opportunities
# vs. opportunities skipped by habit — and this is the only thing that tells the
# two apart. It must never block an iteration.
if [[ -x "$REPO_ROOT/scripts/delegation-audit.sh" ]]; then
  if ! audit_out="$("$REPO_ROOT/scripts/delegation-audit.sh" 2>&1)"; then
    warn "no delegation note in the recent window — read them before trusting the ledger:"
    echo "$audit_out" | sed 's/^/  /' >&2
  fi
fi

if [[ $fail -ne 0 ]]; then
  echo "preflight: environment is not loop-safe — fix the above before running any iteration." >&2
  exit 1
fi
echo "preflight OK"
