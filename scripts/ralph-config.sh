#!/usr/bin/env bash
# ANCHOR: ralph-config — the kit's single per-project seam. Sourced, never run.
#
# Every value that differs between projects lives here and nowhere else. A kit
# script must never carry a project name, repo path, notification title or marker path
# inline: that inlining is exactly what made this scaffolding un-portable in
# the repo it was extracted from, and re-inlining one value is how the kit
# quietly becomes single-project again.
#
# Resolution order, first hit wins:
#   1. the environment                       (CI, one-off overrides, tmux -e)
#   2. $RALPH_REPO_ROOT/.ralph/config.sh     (the project's own settings)
#   3. the documented defaults below
#
# The template config uses `: "${VAR:=value}"` rather than `VAR=value` so that
# order holds — an exported RALPH_MODEL must still beat the file, because the
# driver and heartbeat are routinely launched with per-run overrides.
#
# An unset value therefore resolves to a documented default and NEVER to
# another project's value. That is the property worth protecting here.

_ralph_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${RALPH_REPO_ROOT:=$(cd "$_ralph_here/.." && pwd)}"
: "${RALPH_CONFIG:=$RALPH_REPO_ROOT/.ralph/config.sh}"
unset _ralph_here

if [ -f "$RALPH_CONFIG" ]; then
  # shellcheck source=/dev/null
  . "$RALPH_CONFIG"
fi

# --- identity -----------------------------------------------------------
: "${RALPH_PROJECT_NAME:=$(basename "$RALPH_REPO_ROOT")}"

# --- tmux session names ---------------------------------------------------
# Derived from the project name so two kits on one box run side by side: the
# heartbeat refuses to start while the iteration session exists, and the
# sentinel relaunches the heartbeat by name, so a shared literal `ralph` made
# the second project wait for the first (2026-09-30). tmux rejects `.` and `:`
# in a name, so anything outside [a-z0-9_-] becomes `-`.
_ralph_slug="${RALPH_PROJECT_NAME,,}"
: "${RALPH_TMUX_SESSION:=ralph-${_ralph_slug//[^a-z0-9_-]/-}}"
unset _ralph_slug
: "${RALPH_ITER_SESSION:=${RALPH_TMUX_SESSION}-iter}"
: "${RALPH_SENTINEL_SESSION:=${RALPH_TMUX_SESSION}-sentinel}"
: "${RALPH_OPERATOR_SESSION:=${RALPH_TMUX_SESSION}-operator}"

# --- models (AGENTS.md rule 14: implementer vs review tier) --------------
: "${RALPH_MODEL:=claude-opus-5-5}"
: "${RALPH_REVIEW_MODEL:=claude-fable-5-1}"
# Red is written on the review tier unless the project says otherwise. Defaulted
# here, not only in the template: a config seeded before the red tier existed has
# no such line, and scripts/ralph-iterate.sh would launch red with no model.
: "${RALPH_RED_MODEL:=$RALPH_REVIEW_MODEL}"
# The standing operator (scripts/ralph-operator.sh). On opus by default, not the
# review tier: an operator is a long session that reads a lot and reasons little,
# and on 2026-10-11 26 operator sessions on the review tier cost 4.0M weighted,
# more than the gates they were watching. The cost is that an outage on the
# implementer's pool now also reaches the operator; the owner then starts one on
# the review tier by setting this variable. The budget below is in weighted
# tokens, so the same 3M buys more operator time on opus than it did on fable.
: "${RALPH_OPERATOR_MODEL:=claude-opus-5-5}"
# ...and its context is capped, because a standing session that grows is what
# drained the review tier on 2026-10-03/04: one session at 590k context used about
# 91% of a day's tokens on that tier, all the loop's review-tier stages under 10%.
# Each operator handles one incident; past this cap (the last turn's input + cache
# read + cache write) `ralph-operator.sh wait` returns ROTATE instead of waiting.
: "${RALPH_OPERATOR_CTX_CAP:=150000}"
# ...and its spend over time: operators' weighted tokens (usage-lib.sh weights) in
# a rolling 24 h, from the usage ledger plus the live operator's transcript. When
# it is spent no new operator starts and the stop waits for the owner; 0 = none.
# 3M is about an eighth of what the review tier yielded in a day on 2026-10-04
# (the 590k session's 20.8M weighted was about 91% of a day's tokens on it).
: "${RALPH_OPERATOR_DAILY_BUDGET:=3000000}"
# --- token caps (scripts/token-sentinel.sh) ------------------------------
# A stage that spends more weighted tokens (usage-lib.sh weights) than its cap
# is killed, its ledger row marked over_cap, the owner notified, and the loop
# stops on merit: an accidental leak (a session re-reading a huge file every
# turn, a runaway fan-out) costs one stage, never a day's quota. A tripwire,
# not a budget — the caps sit well above a healthy stage. RALPH_TOKEN_CAP
# covers every headless stage claude-run.sh launches; RALPH_TOKEN_CAP_<STAGE>
# (upper-case, every other character '_') overrides it for one, and the
# implementer session (ralph-driver.sh) has its own below. 0 = no cap.
# Measured (usage-report.sh, two projects, 2026-10): the largest headless row
# was a red at 770k, the largest implementer iteration 70M over 1,530 turns.
: "${RALPH_TOKEN_CAP:=3000000}"
: "${RALPH_TOKEN_CAP_IMPLEMENT:=200000000}"
# Seconds between reads of a live transcript (whole seconds).
: "${RALPH_TOKEN_CAP_POLL:=15}"
# Where the operator repairs the kit: a checkout OUTSIDE this repository (the
# operator is denied every write under it), cloned from RALPH_KIT_REPO if absent.
: "${RALPH_KIT_REPO:=https://github.com/vboscan/wreck-it-ralph.git}"
: "${RALPH_KIT_DIR:=$HOME/.local/ralph-ops/${RALPH_PROJECT_NAME}/kit}"
# Mechanical delegation model (scripts/agy-task.sh). A LABEL from `agy models`,
# not an API id; the label set changes with agy upgrades, so re-check it then.
: "${RALPH_AGY_MODEL:=Gemini 3.8 Flash (High)}"

# --- environment markers ------------------------------------------------
# Headless `agy` dispatch is devbox-only. The image creates this marker; the
# path is per-project so two kits on one box cannot authorise each other.
: "${RALPH_DEVBOX_MARKER:=/etc/ralph-devbox}"
: "${RALPH_DEVBOX_HOSTNAME:=devbox}"

# --- notification (scripts/notify.sh: a comment on a GitHub issue in this repo) ---
: "${RALPH_NOTIFY_TITLE:=$RALPH_PROJECT_NAME}"
: "${RALPH_NOTIFY_ISSUE:=}"                             # pin an issue number; empty = find or create by title
: "${RALPH_NOTIFY_ISSUE_TITLE:=Ralph loop notifications}"
# ntfy retired 2026-09-30; the old title variable stays an alias for one release.
: "${RALPH_NTFY_TITLE:=$RALPH_NOTIFY_TITLE}"

# --- the consuming project's stack --------------------------------------
# ralph/PROMPT.md step 4 runs these three. Empty means "not configured", and
# preflight warns rather than failing: a project may genuinely have no
# typecheck step, and a missing lint command must not block implementation.
: "${RALPH_TEST_CMD:=}"
: "${RALPH_LINT_CMD:=}"
: "${RALPH_TYPECHECK_CMD:=}"

# --- preflight expectations ---------------------------------------------
# Space-separated skill names that must exist under .claude/skills/<n>/SKILL.md.
# `tdd` and `code-review-relative-to-specs` are the two the loop protocol
# actually calls (PROMPT.md steps 3 and 5); the rest are per-project.
: "${RALPH_REQUIRED_SKILLS:=tdd code-review-relative-to-specs}"
