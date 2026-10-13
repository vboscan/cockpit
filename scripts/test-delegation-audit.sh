#!/usr/bin/env bash
# Behavioural tests for scripts/delegation-audit.sh.
#
# The audit answers one question: are loop iterations actually recording the
# `**Delegation**:` note that ralph/PROMPT.md step 6 asks for? That note is the
# delegation ledger's denominator — without it the ledger cannot tell "no
# mechanical opportunities arose" from "opportunities arose and were skipped by
# habit", and both derivation rules in docs/delegation-ledger.md stay blind.
#
# Run: scripts/test-delegation-audit.sh   (exit 0 = all assertions passed)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDIT="${REPO_ROOT}/scripts/delegation-audit.sh"
DATA="${REPO_ROOT}/scripts/testdata/delegation-audit"

pass=0
fail=0

# Compare one field of the audit's output for a fixture directory.
# usage: expect <fixture> <description> <expected-exit> <expected-substring> [extra args...]
expect() {
  local fixture="$1" desc="$2" want_exit="$3" want_text="$4"; shift 4
  local out status
  out="$("${AUDIT}" --since 2026-07-25 --window 3 \
        "${DATA}/${fixture}/PROGRESS.md" "${DATA}/${fixture}/PROGRESS-archive.md" \
        "$@" 2>&1)"
  status=$?
  if [[ "${status}" -eq "${want_exit}" ]] && [[ "${out}" == *"${want_text}"* ]]; then
    pass=$((pass + 1))
    echo "  ok  — ${fixture}: ${desc}"
  else
    fail=$((fail + 1))
    echo "  FAIL — ${fixture}: ${desc}"
    echo "         want exit ${want_exit} containing '${want_text}'"
    echo "         got  exit ${status}: ${out}"
  fi
}

echo "delegation-audit behavioural tests"

# --- the collecting case: the note is being written, denominator is accruing --
expect collecting "3 of 3 recent iterations carry the note → OK" 0 "OK"
expect collecting "reports the marker count it saw" 0 "3/3"

# --- the stale case: the exact failure the audit exists to catch --------------
# Iterations run, none record the note. Silence here is ambiguous by
# construction, so the audit must call it out rather than read it as "no
# opportunities arose".
expect stale "0 of 3 recent iterations carry the note → STALE" 3 "STALE"
expect stale "names the denominator as the thing at risk" 3 "denominator"

# --- prose collision: why the marker is `**Delegation**:` and not `skipped:` --
# PROGRESS entries are long prose paragraphs that legitimately contain the words
# "skipped" and "delegated" (e.g. accepted-finding rationales). A loose grep
# would score those as compliance and report OK forever — the worst failure mode
# for an audit, since it is silently wrong in the reassuring direction.
expect prose-collision "prose 'skipped:'/'delegated:' must NOT count as the note" 3 "STALE"

# --- partial: some but not all — collecting, worth surfacing the ratio --------
expect partial "1 of 3 carries the note → OK but ratio visible" 0 "1/3"

# --- not enough data yet: must not cry STALE before the window is full --------
expect pending "fewer post-policy iterations than the window → PENDING" 0 "PENDING"
expect prepolicy "iterations predating the policy are not counted against it" 0 "PENDING"

# --- the window is a *recent* window, not all-time ----------------------------
# An early burst of compliance must not mask a recent stretch of silence.
expect regressed "old entries carry the note, newest 3 do not → STALE" 3 "STALE"

# --- an entry is a BLOCK, not a line -----------------------------------------
# The log holds the note in two shapes and the audit must see both: appended to
# a one-line entry (`collecting` and `partial` above) and on a line of its own
# inside a multi-paragraph entry (below, and every entry since the format
# settled). The reasoning for each rule lives in delegation-audit.sh; what follows
# is one line per fixture saying which rule it holds. Each verdict is paired with
# the ratio, because an exit code alone cannot tell a correct attribution from
# one that lands on the wrong entry.
expect multiline "the note in a later paragraph of the entry counts" 0 "3/3"

# The block ends at the next entry — otherwise one note is credited upward to
# every newer entry and the audit can never report STALE again.
expect multiline-regressed "an older entry's note does not carry up to newer ones" 3 "STALE"
expect multiline-regressed "and the newest three are scored as the zero they are" 3 "0/3"

# ...and at the next heading of any level, so a worked example under a
# documentation subsection is not credited to the last entry above it.
expect trailing-section "a note below the log's last entry belongs to no entry" 3 "STALE"
expect trailing-section "including under a deeper (###) subsection" 3 "0/3"

# Inside the block the marker must START a line. The log is full of paragraphs
# that quote it — iterations write about this audit — and counting those would
# trade a false STALE for a false OK, the worse of the two.
expect marker-quoted-in-prose "prose quoting the marker mid-sentence is not the note" 3 "STALE"
expect marker-quoted-in-prose "and none of the three is credited with one" 3 "0/3"

# On the header line the marker may sit anywhere — that is the one-line shape —
# so the quotation there is told apart by its backticks instead. Every real note
# in the log reads '. **Delegation**:' and every quotation reads '`**Delegation**:'.
expect header-quotes-marker "a header line quoting the marker as code is not the note" 3 "STALE"
expect header-quotes-marker "even though the marker is on the header line" 3 "0/3"

# A fenced snippet is quoted material: a note-shaped line inside one is a worked
# example, not a note, and a '# ' line inside one is a shell comment, not a
# heading that ends the entry. Entries here are indented list items, so their
# fences are indented too. Only the first entry writes a real note.
expect fenced-example "a note-shaped line inside a snippet is not the note" 0 "1/3"
expect fenced-example "and the entry that writes one below its snippet keeps it" 0 "OK"

# A fence closes only on a delimiter at least as long as the one that opened it.
# The entry most likely to nest fences is the one documenting this marker.
expect fence-nested "a template inside a nested fence is still inside the fence" 3 "STALE"

# An unbalanced fence costs its own entry and nothing more: an entry header ends
# a fence, so one stray ``` cannot swallow the rest of the log and let the window
# backfill from the archive.
expect fence-unbalanced "an unclosed fence does not swallow the entries below it" 0 "2/3"

# The mixed shape the loop's own entries produce: a one-line entry that both
# QUOTES the marker as code and writes the note. Both are on the header line, so
# the audit has to look past the quotation rather than stop at the first match.
expect header-quote-and-note "a header that quotes the marker AND writes the note counts" 0 "3/3"

# The window is "newest first", and within one day only the order the files were
# given can say which entries those are — the loop runs several iterations a day.
expect same-day "same-day entries: the live log is newer than the archive" 0 "OK"
expect same-day "so its notes fill the window, not the archive's silence" 0 "3/3"

# --- the usage text is the header block, however long it grows ----------------
# A fixed line range prints shell code the first time the comment above it gains
# a line, which is how this script's own `-h` came to end on `set -uo pipefail`.
help_out="$("${AUDIT}" --help 2>&1)"; help_status=$?
if [[ "${help_status}" -eq 0 ]] \
  && [[ "${help_out}" == *"usage: scripts/delegation-audit.sh"* ]] \
  && [[ "${help_out}" != *"set -uo pipefail"* ]] \
  && ! grep -q '^#' <<<"${help_out}"; then
  pass=$((pass + 1))
  echo "  ok  — --help: prints the whole header block and no code, unprefixed"
else
  fail=$((fail + 1))
  echo "  FAIL — --help: prints the whole header block and no code, unprefixed"
  echo "         got  exit ${help_status}: ${help_out}"
fi

echo
echo "passed ${pass}, failed ${fail}"
[[ "${fail}" -eq 0 ]]
