#!/usr/bin/env bash
# ANCHOR: delegation-denominator — the spot-check for ralph/PROMPT.md step 6.
#
# docs/delegation-ledger.md records dispatches that happened; it never records
# opportunities seen and passed on. That missing denominator is why "agy was
# used once" is ambiguous: it could mean few mechanical opportunities arose, or
# that they arose and were skipped by habit — opposite problems with opposite
# fixes. Step 6 asks each iteration to close the gap with a `**Delegation**:`
# note. Nothing enforces it, so this audit checks whether it is actually being
# written before anyone reads the ledger's silence as evidence.
#
# usage: scripts/delegation-audit.sh [--since YYYY-MM-DD] [--window N] [file...]
#        defaults: --since 2026-07-26, --window 3, files PROGRESS.md +
#        PROGRESS-archive.md at the repo root — newest log first, which is a
#        contract and not just the default order (see the sort below).
#
# exit 0 = OK or PENDING (note is being written, or too early to tell)
# exit 3 = STALE — the window is full of iterations and none carried the note
# exit 2 = usage error
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The marker is deliberately the literal '**Delegation**:' rather than a bare
# 'skipped:'/'delegated:'. PROGRESS entries are long prose paragraphs that use
# those words for unrelated reasons (accepted-finding rationales, deferred
# work), and a loose grep would score that prose as compliance — an audit that
# is silently wrong in the reassuring direction is worse than none.
#
# The log holds the note in TWO shapes, and both are the note. Early entries are
# one line and append it to that line ('- <date> · <prose>. **Delegation**: …');
# entries since the format settled are multi-paragraph and give it a line of its
# own, which is what ralph/PROMPT.md step 6 now asks for ('one line starting with
# the literal marker'). Counts are not repeated here — docs/delegation-ledger.md
# holds them once, hedged, because they grow every iteration.
#
# So the match is position-sensitive, and differently per shape:
#   - a block's later lines must START with the marker;
#   - an entry's HEADER line may carry it anywhere, EXCEPT immediately after a
#     backtick.
# The exception is what stops the audit reading prose as compliance. Iterations
# write ABOUT this audit, and when they quote the marker they quote it as code —
# every quotation in the log to date is backticked, and every real note is
# preceded by '. ' or '** '. It is a heuristic and worth stating as one: an
# unbackticked mention in a header paragraph would still count, which is a
# residual the block form does not have. Position is checked with index() on the
# raw line rather than a regex, because '**' is regex punctuation and an escaped
# copy of the marker is a second place for the two to drift apart.
MARKER='**Delegation**:'

# Step 6 merged mid-day 2026-07-25 (PR #40), and entries are dated to the day,
# so 07-25's own iterations cannot be judged against a rule that did not exist
# when they ran. Start the clock on the first full day the rule was in force.
since='2026-07-26'
window=3
files=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)  since="${2:-}"; shift 2 ;;
    --window) window="${2:-}"; shift 2 ;;
    # The header block, however long it is: a fixed line range silently starts
    # printing code the first time the comment above grows, which this change did.
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) files+=("$1"); shift ;;
  esac
done

if [[ ${#files[@]} -eq 0 ]]; then
  files=("${REPO_ROOT}/PROGRESS.md" "${REPO_ROOT}/PROGRESS-archive.md")
fi
[[ "${since}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "--since must be YYYY-MM-DD" >&2; exit 2; }
[[ "${window}" =~ ^[0-9]+$ && "${window}" -gt 0 ]] || { echo "--window must be a positive integer" >&2; exit 2; }

# An iteration entry is a BLOCK, not a line. It opens at '- YYYY-MM-DD · <prose>'
# and runs until the next entry or the next heading. Since the entry format
# settled the note lives in one of the block's later paragraphs, so scanning the
# header line alone scored those entries as non-compliant — this audit cried
# STALE against PROGRESS.md for 56 iterations while the note was in fact being
# written (2026-08-10). Emit "date<TAB>0|1" per block, where the flag is a note
# in either shape (see MARKER above), then sort newest-first by date.
#
# The two boundaries are what keep the flag honest in the other direction. End at
# the next entry, or one note is credited to every newer entry above it and the
# audit can never report STALE again. End at the next heading — at ANY level,
# since a worked example is as likely to sit under '### How to write the note' as
# under a top-level section — so documentation about the rule is never read as an
# iteration having followed it.
#
# A fenced code block is quoted material, not the entry's own prose: a snippet
# showing what a note looks like would otherwise BE one, and a '#' line in a
# snippet is a shell comment rather than a heading that ends the entry. Both are
# suspended inside a fence, for backtick and tilde fences alike, and a fence
# closes only on a delimiter at least as long as the one that opened it — an
# entry documenting THIS marker is exactly the one that nests fences.
#
# An entry header always starts an entry, fence or no fence: nothing else bounds
# the damage of one unbalanced fence, which would otherwise swallow every entry
# below it and let the window backfill silently from the archive.
#
# Sorting rather than trusting file order keeps the audit correct if an entry is
# appended out of order or the archive split moves. Within one day it cannot
# order — the loop runs several iterations a day and all of them share a date —
# so the reading order of the files decides, carried by an explicit sequence key
# rather than by `sort -s`'s stability. Hence the contract in the usage note
# above: pass files newest-first, as the default pair is.
# The status is checked, not assumed: this script runs without `set -e`, so an
# awk that rejects the program (a mawk without interval expressions, say) would
# otherwise leave `entries` empty, print PENDING and exit 0 — a parser that is
# entirely broken reporting as a loop that is merely young.
if ! entries="$(
  fileno=0
  for f in "${files[@]}"; do
    fileno=$((fileno + 1))
    [[ -f "$f" ]] || continue
    awk -v marker="${MARKER}" -v fileno="${fileno}" '
      function close_entry() { if (open) { print date "\t" fileno "\t" seq "\t" hit; open = 0 } }
      function trimmed(s) { sub(/^[[:space:]]+/, "", s); return s }
      # The marker as a NOTE rather than as a quotation: any occurrence that is
      # not immediately preceded by a backtick (see MARKER above).
      function unquoted(s,   at, off) {
        for (off = 0; (at = index(substr(s, off + 1), marker)) > 0; off += at)
          if (off + at == 1 || substr(s, off + at - 1, 1) != "`") return 1
        return 0
      }
      /^- [0-9]{4}-[0-9]{2}-[0-9]{2} · / {
        fence = 0; close_entry(); date = $2; seq += 1; hit = unquoted($0); open = 1; next
      }
      /^[[:space:]]*(```|~~~)/ {
        delim = trimmed($0); sub(/[^`~].*$/, "", delim)
        if (!fence) { fence = 1; opench = substr(delim, 1, 1); openlen = length(delim) }
        else if (substr(delim, 1, 1) == opench && length(delim) >= openlen) fence = 0
        next
      }
      fence { next }
      /^#+ / { close_entry() }
      open && index(trimmed($0), marker) == 1 { hit = 1 }
      END { close_entry() }
    ' "$f"
  done | sort -k1,1r -k2,2n -k3,3n
)"; then
  echo "delegation-audit: could not parse the log — see the error above" >&2
  exit 2
fi

total=0
if [[ -n "${entries}" ]]; then
  total="$(printf '%s\n' "${entries}" | awk -v s="${since}" '$1 >= s' | wc -l | tr -d ' ')"
fi

echo "delegation-audit: since=${since} window=${window} marker='${MARKER}'"
echo "  post-policy iterations found: ${total}"

if [[ "${total}" -lt "${window}" ]]; then
  echo "  PENDING — need ${window} iterations since ${since} before the signal means anything (have ${total})."
  exit 0
fi

# Only the newest `window` entries matter: an early burst of compliance must not
# mask a recent stretch of silence.
hits="$(printf '%s\n' "${entries}" \
  | awk -v s="${since}" '$1 >= s' \
  | head -n "${window}" \
  | awk -F'\t' '{n += $4} END {print n + 0}')"

echo "  newest ${window}: ${hits}/${window} carry the note"

if [[ "${hits}" -eq 0 ]]; then
  cat <<EOF
  STALE — ${window} iterations ran since ${since} and none recorded a '${MARKER}' note.
  The denominator is not being collected, so the ledger's silence is NOT evidence
  that no mechanical work was delegable. Rule it out in this order: step 6 omits
  the note entirely when nothing mechanical qualified, so read those ${window} entries
  first — if none of them had qualifying work, they were compliant and nothing needs
  fixing. If they did, fix the reporting: check ralph/PROMPT.md step 6 is still in
  the prompt and that iterations are reaching step 6 at all.
EOF
  exit 3
fi

echo "  OK — the note is being written; ledger row counts can be read as meaningful."
exit 0
