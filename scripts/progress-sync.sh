#!/usr/bin/env bash
# PROGRESS.md's status table must agree with git. (README:
# Q26 / the three-agent brief, 2026-09-21; the README ("Red is written independently").)
#
# usage: scripts/progress-sync.sh [--print]     # exit 0 = consistent, 1 = not
#
# The table is the loop's index (step 1 reads only it), and it is written by
# the same session whose work it describes. This derives, from the default
# branch's history, what the table is allowed to say:
#
#   not-started  → no merged commit names the spec
#   in-progress  → at least one does, on main or on this branch
#   done         → at least one does, on main
#   blocked      → unconstrained
#
# A commit "names" a spec when its subject carries the conventional scope
# `(<NN>)` or the spec's full name `<NN>-<slug>` (specs/00-conventions.md,
# "Commits and PR titles"). --print shows the derived view. Run by merge-pr.sh
# on ralph/* after gate-marker.sh assert-complete.
set -uo pipefail
print=0; [[ "${1:-}" == "--print" ]] && print=1
root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "progress-sync: not a git work tree" >&2; exit 2; }
table="${root}/PROGRESS.md"; [[ -f "${table}" ]] || { echo "progress-sync: no PROGRESS.md" >&2; exit 2; }

base_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
git rev-parse --verify --quiet "${base_ref}" >/dev/null || base_ref="main"
main_subjects="$(git log --format=%s "${base_ref}" 2>/dev/null)"
branch_subjects="$(git log --format=%s "${base_ref}..HEAD" 2>/dev/null)"

names() { # <spec-name> <subjects> → count of subjects naming it
  local n="$1" nn="${1%%-*}"; printf '%s\n' "$2" | grep -cE "\(${nn}(-[^)]*)?\)|(^|[^0-9A-Za-z])${n}([^0-9A-Za-z]|$)" || true
}

fail=0
while IFS='|' read -r _ spec status _; do
  spec="$(echo "${spec}" | xargs)"; status="$(echo "${status}" | xargs)"
  [[ "${spec}" =~ ^[0-9][0-9]- ]] || continue
  on_main="$(names "${spec}" "${main_subjects}")"; on_branch="$(names "${spec}" "${branch_subjects}")"
  case "${status}" in
    not-started) (( on_main + on_branch == 0 )) || { echo "progress-sync: ${spec} is 'not-started' but ${on_main} merged + ${on_branch} pending commits name it" >&2; fail=1; } ;;
    in-progress*) [[ "${status}" =~ ^in-progress\ \(slice\ [0-9]+/[0-9]+\) ]] || { echo "progress-sync: ${spec} has '${status}' — an in-progress status is 'in-progress (slice K/M)', K the slice this branch merges" >&2; fail=1; }
                  (( on_main + on_branch >= 1 )) || { echo "progress-sync: ${spec} is 'in-progress' but no commit on ${base_ref} or this branch names it" >&2; fail=1; } ;;
    done)        (( on_main >= 1 )) || { echo "progress-sync: ${spec} is 'done' but no merged commit on ${base_ref} names it — done means merged" >&2; fail=1; } ;;
    blocked) ;;
    *) echo "progress-sync: ${spec} has unknown status '${status}'" >&2; fail=1 ;;
  esac
  (( print )) && printf '%-28s %-14s merged=%s pending=%s\n' "${spec}" "${status}" "${on_main}" "${on_branch}"
done < <(grep -E '^\| [0-9][0-9]-' "${table}")

# Done rows live in PROGRESS-archive.md (the README ("Hot path")): each must have a merged commit naming it.
archive="${root}/PROGRESS-archive.md"
if [[ -f "${archive}" ]]; then
  while IFS='|' read -r _ spec _; do
    spec="$(echo "${spec}" | xargs)"; [[ "${spec}" =~ ^[0-9][0-9]- ]] || continue
    on_main="$(names "${spec}" "${main_subjects}")"
    (( on_main >= 1 )) || { echo "progress-sync: ${spec} is archived as done but no merged commit on ${base_ref} names it" >&2; fail=1; }
    (( print )) && printf '%-28s %-14s merged=%s\n' "${spec}" "done(archived)" "${on_main}"
  done < <(awk '/^## Done specs/{f=1;next} /^## /{f=0} f && /^\| [0-9][0-9]-/' "${archive}")
fi

if (( fail )); then echo "progress-sync: NOT consistent — fix the table, not the history" >&2; exit 1; fi
echo "progress-sync: consistent with ${base_ref}"
