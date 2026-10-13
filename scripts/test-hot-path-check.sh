#!/usr/bin/env bash
# Behavioural tests for hot-path-check.sh (the README ("Hot path")).
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0; root="$(mktemp -d)"; trap 'rm -rf "${root}"' EXIT
mk() { # <name> → repo dir with minimal hot files
  local d="${root}/$1"; mkdir -p "${d}/ralph" "${d}/specs" "${d}/.claude/skills/tdd"; git init -q "${d}"
  printf '# p\n' > "${d}/ralph/PROMPT.md"; printf '# a\n' > "${d}/AGENTS.md"; printf '# c\n' > "${d}/CLAUDE.md"; printf '# p\n' > "${d}/PLAN.md"
  printf '# c\n' > "${d}/specs/00-conventions.md"; printf '# t\n' > "${d}/.claude/skills/tdd/SKILL.md"; printf '# s\n' > "${d}/specs/01-x.md"
  printf '# P\n\n## Gates\n\n- [ ] a\n\n## Spec status\n\n| Spec | Status | D | B | N |\n|-|-|-|-|-|\n| 01-x | not-started | — | no | |\n\n## Log\n\n' > "${d}/PROGRESS.md"
  echo "${d}"; }
run() { local out st; out="$(cd "$4" && bash "${KIT_SCRIPTS}/hot-path-check.sh" 2>&1)"; st=$?
  if [[ $st -eq $2 ]] && { [[ "$3" == '-' ]] || [[ "$out" == *"$3"* ]]; }; then pass=$((pass+1)); echo "  ok  — $1"
  else fail=$((fail+1)); echo "  FAIL — $1"; echo "         want $2 containing '$3'; got $st: $out"; fi; }
echo "hot-path-check.sh"
r="$(mk small)"; run "minimal files → within budget" 0 "within budget" "$r"
r="$(mk bigprompt)"; head -c 24000 /dev/zero | tr '\0' 'x' > "$r/ralph/PROMPT.md"; run "PROMPT.md over 5000 tokens → over budget" 1 "PROMPT.md is" "$r"
r="$(mk padded)"; sed -i 's/| 01-x | not-started |/| 01-x   | not-started |/' "$r/PROGRESS.md"; run "padded table cell → refused" 1 "padded table cells" "$r"
r="$(mk done)"; sed -i 's/not-started/done/' "$r/PROGRESS.md"; run "a done row in the hot table → refused" 1 "carries done rows" "$r"
r="$(mk log)"; for i in 1 2 3 4; do printf '### entry %d\nline\n' "$i" >> "$r/PROGRESS.md"; done; run "four log entries → refused" 1 "log has 4 entries" "$r"
r="$(mk longentry)"; { echo "### e1"; for i in $(seq 1 30); do echo "l$i"; done; } >> "$r/PROGRESS.md"; run "a 30-line entry → refused" 1 "exceeds 25 lines" "$r"
r="$(mk emptycell)"; run "an empty Notes cell is not padding" 0 "within budget" "$r"
r="$(mk longnote)"; sed -i 's/| 01-x | not-started | — | no | |/| 01-x | not-started | — | no | slice 2 of 4 landed; slice 3 blocked on the cert; accepted finding about the janitor selector |/' "$r/PROGRESS.md"; run "a Notes cell over 60 chars → refused" 1 "Notes over 60 chars" "$r"
r="$(mk unlisted)"; printf '## Iteration\n\n1. Read `PROGRESS.md` and `docs/COMPONENTS.md` first.\n2. Branch.\n' > "$r/ralph/PROMPT.md"; run "PROMPT.md naming an unbudgeted start-of-iteration read → refused" 1 "docs/COMPONENTS.md as a start-of-iteration read" "$r"
r="$(mk listedok)"; printf '## Iteration\n\n1. Read `PROGRESS.md` and `specs/00-conventions.md` and the spec.\n2. Branch.\n' > "$r/ralph/PROMPT.md"; run "PROMPT.md naming only budgeted reads → fine" 0 "within budget" "$r"
echo "  ${pass} passed, ${fail} failed"; [[ $fail -eq 0 ]]
