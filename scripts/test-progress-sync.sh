#!/usr/bin/env bash
# Behavioural tests for progress-sync.sh.
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0; root="$(mktemp -d)"; trap 'rm -rf "${root}"' EXIT
new_repo() { local d="${root}/$1"; mkdir -p "${d}"; git init -q --bare "${d}/remote.git"; git init -q "${d}/repo"
  ( cd "${d}/repo" && git config user.email t@x && git config user.name t && git remote add origin "${d}/remote.git" \
    && printf '| Spec | Status | D | B | N |\n|-|-|-|-|-|\n| 01-scaffold | %s | — | no | |\n| 02-infra | %s | 01 | no | |\n' "$2" "$3" > PROGRESS.md \
    && git add -A && git commit -qm "init" && git branch -M main && git push -q origin main && git remote set-head origin main ); echo "${d}/repo"; }
main_commit() { git -C "$1" commit -q --allow-empty -m "$2" && git -C "$1" push -q origin main; }
run() { local out st; out="$(cd "$4" && bash "${KIT_SCRIPTS}/progress-sync.sh" 2>&1)"; st=$?
  if [[ $st -eq $2 ]] && { [[ "$3" == '-' ]] || [[ "$out" == *"$3"* ]]; }; then pass=$((pass+1)); echo "  ok  — $1"
  else fail=$((fail+1)); echo "  FAIL — $1"; echo "         want $2 containing '$3'; got $st: $out"; fi; }

echo "progress-sync.sh"
r="$(new_repo fresh not-started not-started)"; run "fresh table, no commits → consistent" 0 "consistent" "$r"
r="$(new_repo lie not-started done)"; run "'done' with nothing merged → not consistent" 1 "02-infra is 'done'" "$r"
r="$(new_repo done done not-started)"; main_commit "$r" "feat(01): scaffold lands (#3)"; run "'done' with a merged (01) commit → consistent" 0 "consistent" "$r"
r="$(new_repo stale not-started not-started)"; main_commit "$r" "feat(01-scaffold): first slice (#4)"; run "'not-started' but a merged commit names it → not consistent" 1 "01-scaffold is 'not-started'" "$r"
r="$(new_repo pending not-started not-started)"; ( cd "$r" && git checkout -qb ralph/02-infra && sed -i 's/| 02-infra | not-started/| 02-infra | in-progress (slice 1\/2)/' PROGRESS.md && git commit -qam "feat(02): slice 1" )
run "'in-progress' with the naming commit still on the branch → consistent" 0 "consistent" "$r"
r="$(new_repo prose not-started not-started)"; ( cd "$r" && git checkout -qb ralph/02-infra && sed -i 's/| 02-infra | not-started/| 02-infra | in-progress (slice 1 of 2)/' PROGRESS.md && git commit -qam "feat(02): slice 1" )
run "'in-progress' not in the 'slice K/M' form → not consistent (stop #67)" 1 "02-infra has 'in-progress (slice 1 of 2)'" "$r"
r="$(new_repo bare not-started not-started)"; ( cd "$r" && git checkout -qb ralph/02-infra && sed -i 's/| 02-infra | not-started/| 02-infra | in-progress/' PROGRESS.md && git commit -qam "feat(02): slice 1" )
run "bare 'in-progress' → not consistent" 1 "slice K/M" "$r"
r="$(new_repo blocked blocked not-started)"; run "'blocked' is unconstrained" 0 "consistent" "$r"
echo "  ${pass} passed, ${fail} failed"; [[ $fail -eq 0 ]]
