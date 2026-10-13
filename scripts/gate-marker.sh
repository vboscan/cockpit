#!/usr/bin/env bash
# ANCHOR: ralph-gate-marker — make ralph/PROMPT.md step 5's gate sequence
# resumable without ever skipping a gate against code it did not read.
#
# Why this exists: the loop's checkpoints were red/green/gated only, so a
# usage-limit death during the third gate resumed at `green` and re-ran all
# four — a gate that had already passed bought nothing, because its verdict
# lived only in the context of the session that was killed. Running the gates
# sequentially (step 5) stops one iteration from draining the window; it does
# nothing to preserve the gates already finished when the window drains anyway.
#
# The verdict is therefore persisted as an empty commit naming the tree it
# vouches for, and `check` authorises a skip only on exact tree-sha equality.
#
#   scripts/gate-marker.sh record <gate> [label...]
#   scripts/gate-marker.sh check  <gate>
#   scripts/gate-marker.sh assert-complete
#
# exit 0 = recorded | skip the gate | cleared to merge
# exit 1 = check: RUN the gate (no marker, stale marker, or any doubt)
#          assert-complete: NOT cleared, with the reason on stderr
# exit 2 = usage error (unknown gate name or subcommand)
# exit 3 = record only: refused — the tree is dirty, so nothing can be vouched
#
# `record` and `check` are opt-in by nature: a session that never calls them
# simply has no markers, and silence is indistinguishable from diligence. That
# is what `assert-complete` closes — scripts/merge-pr.sh calls it on `ralph/*`
# branches, so an iteration cannot land unless every gate is accounted for
# since checkpoint(green). It reads git state only; nothing it decides depends
# on parsing gate output or on what a session claims it did.
#
# Two properties are load-bearing, and scripts/test-gate-marker.sh pins both:
#
#   1. The identifier is the *tree* sha, never the commit sha. The marker is an
#      empty commit, so it leaves the tree untouched and the identifier stays
#      stable as markers accumulate; keyed on the commit sha, every marker would
#      invalidate the one before it and the mechanism would be a no-op.
#   2. Marker *presence* never authorises anything. A grep for the gate name
#      alone would skip a gate against a tree it never read, which is the one
#      failure this script exists to prevent — so every ambiguous state (no
#      marker, malformed marker, no commits, not a repo) resolves to "run it".
#
# Content-addressing gives property 2 for free in the awkward direction too: a
# tree reverted to identical bytes IS the tree the gate read, so skipping is
# correct there rather than a loophole.
set -uo pipefail

# The gates of ralph/PROMPT.md step 5, spelled exactly as the prompt spells
# them. Closed set on purpose: a typo must not silently record a marker nobody
# checks, nor silently check a marker nobody records.
GATES=(security-review code-review code-review-relative-to-specs verify)
# `confirm` is recorded like a gate but is not one: it attests that the delta
# between what the gates read and the final tree has been reconciled (step 5's
# confirm pass). assert-complete demands it only when that delta is non-empty.
MARKERS=("${GATES[@]}" confirm)

# Print the header block rather than a hardcoded line range — the range drifts
# silently every time the header is edited, and a stale --help is a small lie
# in a script whose whole job is refusing to state things it cannot back up.
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

die_usage() { echo "gate-marker: $1" >&2; echo >&2; usage >&2; exit 2; }

valid_gate() {
  local g
  for g in "${MARKERS[@]}"; do [[ "$1" == "${g}" ]] && return 0; done
  return 1
}

# The tree sha a marker vouches for, or empty when the gate has no marker in
# the given commit range. Subject form: 'checkpoint(gate:NAME) tree=SHA: label'.
marker_tree() {
  local gate="$1" range="$2" prefix
  prefix="checkpoint(gate:${gate}) tree="
  git log --format=%s ${range} 2>/dev/null \
    | awk -v p="${prefix}" 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }' \
    | cut -d: -f1
}

# The tree HEAD points at, or empty when there is nothing to point at (no
# commits, not a repo). Callers treat empty as "cannot vouch".
head_tree() { git rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null; }

cmd="${1:-}"
case "${cmd}" in
  -h|--help) usage; exit 0 ;;
  record|check|assert-complete) ;;
  "") die_usage "no subcommand given" ;;
  *) die_usage "unknown subcommand: ${cmd}" ;;
esac

if [[ "${cmd}" == "assert-complete" ]]; then
  # The exit gate. `record`/`check` stay opt-in by nature — a session that never
  # calls them simply has no markers — so this is what makes the omission fatal
  # rather than invisible. Everything below is derived from git state alone: no
  # parsing of gate output, no trust in what a session says it did.
  cur="$(head_tree)"
  [[ -n "${cur}" ]] || { echo "gate-marker: no HEAD tree — NOT cleared" >&2; exit 1; }

  # checkpoint(green) opens the review window. Markers older than it belong to a
  # previous round and vouch for a tree this iteration has already moved past.
  green="$(git log --format='%H%x09%s' 2>/dev/null \
           | awk -F'\t' 'index($2, "checkpoint(green)") == 1 { print $1; exit }')"
  if [[ -z "${green}" ]]; then
    cat >&2 <<EOF
gate-marker: NOT cleared — no checkpoint(green) commit on this branch.
  Without it there is no window to judge the gates against (ralph/PROMPT.md
  step 4). Run the suite, commit checkpoint(green), then the gates.
EOF
    exit 1
  fi

  missing=()
  stale=0
  for g in "${GATES[@]}"; do
    t="$(marker_tree "${g}" "${green}..HEAD")"
    if [[ -z "${t}" ]]; then missing+=("${g}")
    elif [[ "${t}" != "${cur}" ]]; then stale=1
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "gate-marker: NOT cleared — no marker since checkpoint(green) for: ${missing[*]}" >&2
    echo "  Run each gate, then: scripts/gate-marker.sh record <gate> <spec> <slice>" >&2
    exit 1
  fi

  # Every gate marker matches the current tree: nothing changed after the gates
  # ran, so what merges IS what they read and there is no delta to confirm.
  if [[ "${stale}" -eq 0 ]]; then
    echo "gate-marker: cleared — all ${#GATES[@]} gates vouch for tree ${cur}, no delta to confirm"
    exit 0
  fi

  # Otherwise fixes landed after some gate read the tree, so the merged tree is
  # not the tree that gate reviewed. Step 5's confirm pass is the only thing
  # that has read the final state, which is why it — and only it — must match
  # the current sha exactly.
  ct="$(marker_tree confirm "${green}..HEAD")"
  if [[ "${ct}" == "${cur}" ]]; then
    echo "gate-marker: cleared — all ${#GATES[@]} gates recorded, confirm pass current for tree ${cur}"
    exit 0
  fi

  cat >&2 <<EOF
gate-marker: NOT cleared — the tree moved after the gates read it.
  All ${#GATES[@]} gates are recorded, but at least one vouches for an older tree, and
  the confirm pass is $( [[ -z "${ct}" ]] && echo "missing" || echo "stale (vouches for ${ct}, tree is now ${cur})" ).
  What merges to main is not what any gate read. Run step 5's confirm pass over
  the checkpoint(green)..HEAD delta, then: scripts/gate-marker.sh record confirm
EOF
  exit 1
fi

gate="${2:-}"
[[ -n "${gate}" ]] || die_usage "no gate name given"
valid_gate "${gate}" || die_usage "unknown gate: ${gate} (expected one of: ${GATES[*]})"
shift 2

if [[ "${cmd}" == "record" ]]; then
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "gate-marker: not inside a git work tree — nothing to record" >&2; exit 3; }

  # The gate reads the working tree; HEAD^{tree} does not describe it while
  # edits are uncommitted. Recording here would vouch for a tree that nothing
  # reviewed, which is exactly the lie `check` is built to refuse — so commit
  # the fixes first and let the marker sit on top of them.
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    cat >&2 <<EOF
gate-marker: refusing to record '${gate}' — the working tree is dirty.
  The marker vouches for HEAD's tree, but uncommitted edits mean HEAD is not
  what the gate reviewed. Commit the gate's fixes first, then record:
    git add -A && git commit -m "fix(<spec>): <gate> findings"
    scripts/gate-marker.sh record ${gate} <spec> <slice>
EOF
    exit 3
  fi

  tree="$(head_tree)"
  [[ -n "${tree}" ]] || { echo "gate-marker: HEAD has no tree (no commits yet) — nothing to record" >&2; exit 3; }

  label="$*"
  [[ -n "${label}" ]] || label="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

  git commit --allow-empty -q -m "checkpoint(gate:${gate}) tree=${tree}: ${label}" || {
    echo "gate-marker: could not write the marker commit" >&2; exit 3; }
  echo "gate-marker: recorded ${gate} against tree ${tree}"
  exit 0
fi

# --- check -------------------------------------------------------------------
# Every failure path below lands on exit 1. That is the whole safety posture:
# the expensive outcome is re-running a gate, the unacceptable one is skipping
# it, so doubt always costs tokens rather than coverage.
tree="$(head_tree)"
if [[ -z "${tree}" ]]; then
  echo "gate-marker: no HEAD tree (not a repo, or no commits) — run ${gate}"
  exit 1
fi

# Prefix-anchored via awk rather than grep so the parentheses in the marker
# need no regex escaping. The sha is fixed-length hex followed by ':', so a
# prefix match cannot collide with a longer sha.
prefix="checkpoint(gate:${gate}) tree=${tree}"
hit="$(git log --format=%s 2>/dev/null | awk -v p="${prefix}" 'index($0, p) == 1 { print "hit"; exit }')"

if [[ -n "${hit}" ]]; then
  echo "gate-marker: ${gate} already vouched for tree ${tree} — skip"
  exit 0
fi

echo "gate-marker: no valid ${gate} marker for tree ${tree} — run ${gate}"
exit 1
