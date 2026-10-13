#!/usr/bin/env bash
# Behavioural tests for scripts/gate-marker.sh.
#
# The marker exists so a usage-limit death mid-gate-sequence does not re-spend
# the gates that already passed (ralph/PROMPT.md step 5). That makes `check` a
# skip-authoriser, and a skip-authoriser has one catastrophic failure mode:
# authorising a skip for code the gate never read. Every assertion below exists
# to pin that shut — the safety property is tree-sha *equality*, never marker
# presence, and every ambiguous state must resolve to "run the gate".
#
# Run: scripts/test-gate-marker.sh   (exit 0 = all assertions passed)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKER="${REPO_ROOT}/scripts/gate-marker.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT

# A throwaway repo per test — never the real one. Echoes its path.
new_repo() {
  local dir
  dir="$(mktemp -d "${TMPROOT}/repo.XXXXXX")"
  git -C "${dir}" init -q
  git -C "${dir}" config user.email t@t.t
  git -C "${dir}" config user.name t
  echo "content-a" > "${dir}/file.txt"
  git -C "${dir}" add -A
  git -C "${dir}" commit -qm "base"
  echo "${dir}"
}

# usage: expect <description> <expected-exit> <repo> <args...>
expect() {
  local desc="$1" want_exit="$2" repo="$3"; shift 3
  local out status
  out="$(cd "${repo}" && "${MARKER}" "$@" 2>&1)"
  status=$?
  if [[ "${status}" -eq "${want_exit}" ]]; then
    pass=$((pass + 1))
    echo "  ok  — ${desc}"
  else
    fail=$((fail + 1))
    echo "  FAIL — ${desc}"
    echo "         want exit ${want_exit}, got ${status}: ${out}"
  fi
}

echo "gate-marker behavioural tests"
echo
echo "-- exit contract: check 0=skip 1=must-run 2=usage; record 0=ok 3=dirty --"

# --- no marker at all: the default must be to run the gate -------------------
r="$(new_repo)"
expect "no marker recorded → must run" 1 "${r}" check code-review

# --- the happy path: record, then the same tree authorises a skip ------------
r="$(new_repo)"
( cd "${r}" && "${MARKER}" record code-review >/dev/null 2>&1 )
expect "marker recorded against current tree → skip" 0 "${r}" check code-review

# --- a marker is per-gate, not global ----------------------------------------
expect "a different gate has no marker → must run" 1 "${r}" check security-review

# --- the marker commit must not itself disturb the tree ----------------------
# If recording changed the tree, the marker would invalidate itself and the
# whole mechanism would be a no-op that silently always re-runs.
r="$(new_repo)"
before="$(git -C "${r}" rev-parse 'HEAD^{tree}')"
n_before="$(git -C "${r}" rev-list --count HEAD)"
( cd "${r}" && "${MARKER}" record code-review >/dev/null 2>&1 )
after="$(git -C "${r}" rev-parse 'HEAD^{tree}')"
n_after="$(git -C "${r}" rev-list --count HEAD)"
# Both halves matter: a commit must actually land (else the mechanism is a
# no-op), and it must not move the tree (else the marker invalidates itself).
if [[ "${before}" == "${after}" && "${n_after}" -eq "$((n_before + 1))" ]]; then
  pass=$((pass + 1)); echo "  ok  — recording adds one commit and leaves the tree sha unchanged"
else
  fail=$((fail + 1))
  echo "  FAIL — recording must add exactly 1 commit without moving the tree"
  echo "         tree ${before} -> ${after}; commits ${n_before} -> ${n_after}"
fi

# --- THE core safety property: tree changed → the verdict is stale -----------
r="$(new_repo)"
( cd "${r}" && "${MARKER}" record code-review >/dev/null 2>&1 )
echo "content-b" > "${r}/file.txt"
git -C "${r}" add -A && git -C "${r}" commit -qm "a fix"
expect "tree changed after recording → must run" 1 "${r}" check code-review

# --- presence is never sufficient: a hand-written marker with a wrong sha ----
# This is the failure mode the whole design turns on. A grep for the gate name
# alone would authorise a skip here, against code the gate never read.
r="$(new_repo)"
git -C "${r}" commit -q --allow-empty \
  -m "checkpoint(gate:code-review) tree=0000000000000000000000000000000000000000: forged"
expect "marker present but sha mismatched → must run" 1 "${r}" check code-review

# --- a marker with no tree= field at all is not a licence to skip ------------
r="$(new_repo)"
git -C "${r}" commit -q --allow-empty -m "checkpoint(gate:code-review): no sha here"
expect "malformed marker (no tree= field) → must run" 1 "${r}" check code-review

# --- reverting to identical content is genuinely the same tree ---------------
# Not a loophole: git trees are content-addressed, so an identical tree *is*
# the bytes the gate read. Re-running would be pure waste.
r="$(new_repo)"
( cd "${r}" && "${MARKER}" record code-review >/dev/null 2>&1 )
echo "content-b" > "${r}/file.txt"
git -C "${r}" add -A && git -C "${r}" commit -qm "change"
echo "content-a" > "${r}/file.txt"
git -C "${r}" add -A && git -C "${r}" commit -qm "revert"
expect "tree reverted to identical content → skip is sound" 0 "${r}" check code-review

# --- recording against a dirty tree must be refused --------------------------
# The gate reads the working tree; HEAD^{tree} does not describe it while edits
# are uncommitted. Recording anyway would vouch for a tree nothing reviewed.
r="$(new_repo)"
echo "uncommitted fix" >> "${r}/file.txt"
expect "record on a dirty tree → refused" 3 "${r}" record code-review

# --- untracked files count as dirty too --------------------------------------
r="$(new_repo)"
echo "new" > "${r}/untracked.txt"
expect "record with untracked files → refused" 3 "${r}" record code-review

# --- unknown gate names are a usage error on both subcommands ----------------
# A typo must not silently record a marker nobody checks, nor silently check a
# marker nobody records.
r="$(new_repo)"
expect "record with an unknown gate name → usage error" 2 "${r}" record cod-review
expect "check with an unknown gate name → usage error" 2 "${r}" check cod-review
expect "missing gate name → usage error" 2 "${r}" check
expect "unknown subcommand → usage error" 2 "${r}" frobnicate code-review

# --- all four gate names in the step 5 sequence are accepted -----------------
for g in security-review code-review code-review-relative-to-specs verify; do
  r="$(new_repo)"
  expect "gate name '${g}' is accepted" 0 "${r}" record "${g}"
done

# --- outside a git repo: fail safe, never authorise a skip -------------------
nonrepo="$(mktemp -d "${TMPROOT}/bare.XXXXXX")"
expect "check outside a git repo → must run (fail safe)" 1 "${nonrepo}" check code-review

# --- a repo with no commits yet: also fail safe ------------------------------
empty="$(mktemp -d "${TMPROOT}/empty.XXXXXX")"
git -C "${empty}" init -q
expect "check with no commits → must run (fail safe)" 1 "${empty}" check code-review

echo
echo "-- assert-complete: the exit gate, derived purely from git state --------"
# Recording and checking are still opt-in: a session that never calls them
# simply has no markers. `assert-complete` is what makes that fatal instead of
# invisible — it refuses to clear an iteration for checkpoint(gated)/merge
# unless every gate is accounted for since checkpoint(green). No output
# parsing, no trust in the session's narration; only git state.

# Helpers that build a realistic step-5 history.
mk_green() { git -C "$1" commit -q --allow-empty -m "checkpoint(green): spec slice"; }
mk_all_gates() {
  local d="$1" g
  for g in security-review code-review code-review-relative-to-specs verify; do
    ( cd "${d}" && "${MARKER}" record "${g}" spec slice >/dev/null 2>&1 )
  done
}
mk_fix() { echo "fix-$2" > "$1/file.txt"; git -C "$1" add -A; git -C "$1" commit -qm "fix: $2"; }

# --- no checkpoint(green): the review window cannot even be established ------
r="$(new_repo)"
mk_all_gates "${r}"
expect "no checkpoint(green) → not cleared" 1 "${r}" assert-complete

# --- the clean happy path: green, four gates, nothing changed since ----------
r="$(new_repo)"; mk_green "${r}"; mk_all_gates "${r}"
expect "green + all four gates at the current tree → cleared" 0 "${r}" assert-complete

# --- a missing gate is fatal, and must be named ------------------------------
r="$(new_repo)"; mk_green "${r}"
for g in security-review code-review verify; do
  ( cd "${r}" && "${MARKER}" record "${g}" spec slice >/dev/null 2>&1 )
done
expect "one gate never recorded → not cleared" 1 "${r}" assert-complete
out="$(cd "${r}" && "${MARKER}" assert-complete 2>&1)"
if [[ "${out}" == *"code-review-relative-to-specs"* ]]; then
  pass=$((pass + 1)); echo "  ok  — names the missing gate"
else
  fail=$((fail + 1)); echo "  FAIL — did not name the missing gate: ${out}"
fi

# --- markers predating checkpoint(green) are from a previous round -----------
# They vouch for a tree the current green state has already moved past.
r="$(new_repo)"; mk_all_gates "${r}"; mk_fix "${r}" one; mk_green "${r}"
expect "gate markers recorded before checkpoint(green) do not count" 1 "${r}" assert-complete

# --- fixes landed after the gates: the confirm pass becomes mandatory --------
# This is the case that motivated the whole confirm pass — the merged tree is
# not the tree any gate read.
r="$(new_repo)"; mk_green "${r}"; mk_all_gates "${r}"; mk_fix "${r}" after-gates
expect "tree moved after the gates, no confirm → not cleared" 1 "${r}" assert-complete

r="$(new_repo)"; mk_green "${r}"; mk_all_gates "${r}"; mk_fix "${r}" after-gates
( cd "${r}" && "${MARKER}" record confirm spec slice >/dev/null 2>&1 )
expect "tree moved after the gates, confirm recorded → cleared" 0 "${r}" assert-complete

# --- a confirm marker is itself sha-guarded ----------------------------------
r="$(new_repo)"; mk_green "${r}"; mk_all_gates "${r}"; mk_fix "${r}" after-gates
git -C "${r}" commit -q --allow-empty \
  -m "checkpoint(gate:confirm) tree=0000000000000000000000000000000000000000: forged"
expect "confirm marker with a mismatched sha → not cleared" 1 "${r}" assert-complete

# --- editing after the confirm pass invalidates it ---------------------------
# The confirm marker is the freshness anchor: it is the only thing that has
# read the final state, so anything after it reopens the gap.
r="$(new_repo)"; mk_green "${r}"; mk_all_gates "${r}"; mk_fix "${r}" after-gates
( cd "${r}" && "${MARKER}" record confirm spec slice >/dev/null 2>&1 )
mk_fix "${r}" sneaked-in-later
expect "a fix landed after the confirm pass → not cleared" 1 "${r}" assert-complete

# --- 'confirm' is a first-class marker name for record/check -----------------
r="$(new_repo)"
expect "gate name 'confirm' is accepted by record" 0 "${r}" record confirm
expect "gate name 'confirm' is accepted by check" 0 "${r}" check confirm

echo
echo "passed ${pass}, failed ${fail}"
[[ "${fail}" -eq 0 ]]
