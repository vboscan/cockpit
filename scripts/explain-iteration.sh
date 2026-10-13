#!/usr/bin/env bash
# The "for dummies" summary of one merged iteration (README, "The per-iteration explainer").
#
# usage: scripts/explain-iteration.sh <pr-number> <spec-file> [<merge-commit>]
#
# A FRESH headless session on a cheap reading tier ($RALPH_EXPLAIN_MODEL) reads
# the spec's "Why it matters" section, the PROGRESS.md entry and the merged
# diff, and writes ~150 plain words: what exists now that did not, what it
# proves toward the stage, what to look at. It judges nothing, so it never
# needs the review tier, and it runs AFTER the merge, outside the iteration's
# usage window, so it can never cost a slice. Delivered as a comment on the PR
# (scripts/comment-pr.sh) and to the notifications issue (scripts/notify.sh). Every
# failure is a warning: a summary must never block the loop.
set -uo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph-config.sh"

pr="${1-}"; spec="${2-}"; commit="${3:-HEAD}"
if [ -z "${pr}" ] || [ ! -f "${spec}" ]; then
  echo "usage: $(basename "$0") <pr-number> <spec-file> [<merge-commit>]" >&2; exit 2
fi
repo_root="$(git rev-parse --show-toplevel)"
out="$(mktemp)"; trap 'rm -f "$out"' EXIT

why=$(awk '/^## Why it matters/{f=1;next} /^## /{f=0} f' "${spec}")
entry=$(awk -v pr="#${pr}" 'index($0, pr){f=1} f&&/^## |^- \*\*/{c++} f{print} c>1{exit}' "${repo_root}/PROGRESS.md" | head -60)
diff=$(git -C "${repo_root}" show --stat --format='%s%n%n%b' "${commit}" | head -80)

prompt=$(cat <<P
You explain software progress to a smart person who does not code. Write at most 150 words, plain
language, no jargon without a one-clause gloss, no bullet spam. Structure: (1) what exists now that did
not before this change, (2) what it proves or measures toward the experiment stage named below, (3) one
concrete thing the reader could look at or try. Do not judge quality; do not invent results.

SPEC ($(basename "${spec}")) — why it matters:
${why}

PROGRESS.md entry for PR #${pr}:
${entry}

Merged change (stat + message):
${diff}
P
)

if ! "${repo_root}/scripts/claude-run.sh" explain "$(basename "${spec}" | cut -c1-2)" "pr${pr}" -- -p --model "${RALPH_EXPLAIN_MODEL}" "${prompt}" > "${out}" 2>/dev/null || [ ! -s "${out}" ]; then
  echo "warn: explainer session failed or returned nothing — no summary for PR #${pr}" >&2; exit 1
fi
specnum="$(basename "${spec}" | cut -c1-2)"
{ printf '**For dummies — iteration for %s (PR #%s)**\n\n' "$(basename "${spec}" .md)" "${pr}"; cat "${out}"
  if [[ -x "${repo_root}/scripts/usage-report.sh" ]] && report="$("${repo_root}/scripts/usage-report.sh" --spec "${specnum}" 2>/dev/null)"; then
    printf '\n<details><summary>Where the budget went (spec %s, weighted tokens)</summary>\n\n```\n%s\n```\n</details>\n' "${specnum}" "${report}"
  fi; } > "${out}.md"
"${repo_root}/scripts/comment-pr.sh" "${pr}" --body-file "${out}.md" || echo "warn: PR comment failed" >&2
RALPH_NOTIFY_KIND=info "${repo_root}/scripts/notify.sh" -t "${RALPH_NOTIFY_TITLE} — PR #${pr} explained" "$(cat "${out}.md")" || echo "warn: notify failed" >&2
rm -f "${out}.md"
