#!/usr/bin/env bash
# Hot-path budgets (the README ("Hot path")). Anything read at the start of an iteration is
# re-sent on every turn (~300×), so its cost is size × turns. Tokens are
# estimated as bytes/4. Exit 0 = within budget, 1 = over, 2 = usage.
#
# usage: scripts/hot-path-check.sh [--print]
#
# Budgets (tokens) — change them here AND in the file's header comment:
#   ralph/PROMPT.md 5000 · AGENTS.md 2500 · specs/00-conventions.md 1800 ·
#   PLAN.md 1200 · PROGRESS.md 2000 (table ≤ 1200, gates ≤ 12 lines, log ≤ 3 entries
#   of ≤ 25 lines) · each specs/NN 900 · .claude/skills/tdd/SKILL.md 1500 ·
#   CLAUDE.md 900. Total ≤ 13000 with one spec.
# Also refuses: padded table cells (two or more spaces between content and a
# pipe) in any hot file, and `done` rows in PROGRESS.md's table.
set -uo pipefail
print=0; [[ "${1:-}" == "--print" ]] && print=1
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "${root}" || exit 2
tok() { [[ -f "$1" ]] && echo $(( $(wc -c < "$1") / 4 )) || echo 0; }
fail=0; total=0
check() { # <file> <budget>
  local t; t="$(tok "$1")"; total=$((total + t))
  (( print )) && printf '%-40s %6d / %-6d\n' "$1" "$t" "$2"
  if (( t > $2 )); then echo "hot-path: $1 is ${t} tokens, budget $2" >&2; fail=1; fi
  if [[ -f "$1" ]] && grep -qE '[^ |] {2,}\|' "$1"; then echo "hot-path: $1 has padded table cells" >&2; fail=1; fi
}
check ralph/PROMPT.md 5000
check AGENTS.md 2500
check CLAUDE.md 900
check PLAN.md 1200
check PROGRESS.md 2000
check specs/00-conventions.md 1800
check .claude/skills/tdd/SKILL.md 1500
# The one spec an iteration reads: budget each, count the largest toward the total.
largest=0
for s in specs/[0-9][0-9]-*.md; do
  [[ "$s" == specs/00-* ]] && continue
  t="$(tok "$s")"; (( t > largest )) && largest=$t
  if (( t > 900 )); then echo "hot-path: $s is ${t} tokens, budget 900" >&2; fail=1; fi
done
total=$((total + largest)); (( print )) && printf '%-40s %6d / %-6d\n' "largest spec" "$largest" 900

if [[ -f PROGRESS.md ]]; then
  gates="$(awk '/^## Gates/{f=1;next} /^## /{f=0} f && /^- \[/' PROGRESS.md | wc -l)"
  (( gates > 12 )) && { echo "hot-path: PROGRESS.md gates: ${gates} lines, max 12" >&2; fail=1; }
  table_bytes="$(grep -E '^\|' PROGRESS.md | wc -c)"
  (( table_bytes / 4 > 1200 )) && { echo "hot-path: PROGRESS.md table is $((table_bytes/4)) tokens, max 1200 — move done rows to PROGRESS-archive.md" >&2; fail=1; }
  grep -qE '^\| [0-9][0-9]-[^|]*\| done ' PROGRESS.md && { echo "hot-path: PROGRESS.md carries done rows — move them to PROGRESS-archive.md" >&2; fail=1; }
  # Notes ≤ 60 chars per row: the cell where the log leaks into the index.
  while IFS= read -r row; do
    note="$(printf '%s' "${row}" | awk -F'|' '{print $6}' | sed 's/^ *//; s/ *$//')"
    if (( ${#note} > 60 )); then echo "hot-path: PROGRESS.md Notes over 60 chars in row: ${row:0:40}…" >&2; fail=1; fi
  done < <(grep -E '^\| [0-9][0-9]-' PROGRESS.md)
  entries="$(awk '/^## Log/{f=1;next} f && /^### /' PROGRESS.md | wc -l)"
  (( entries > 3 )) && { echo "hot-path: PROGRESS.md log has ${entries} entries, max 3 — move older ones to PROGRESS-archive.md" >&2; fail=1; }
  awk '/^## Log/{f=1;next} f && /^### /{if(n>25){bad=1}; n=0; next} f{n++} END{if(n>25)bad=1; exit bad}' PROGRESS.md \
    || { echo "hot-path: a PROGRESS.md log entry exceeds 25 lines" >&2; fail=1; }
fi
# Every file PROMPT.md names as a start-of-iteration read must be in this
# check's list, or a spec — otherwise a new hot file joins with no budget.
if [[ -f ralph/PROMPT.md ]]; then
  listed="ralph/PROMPT.md AGENTS.md CLAUDE.md PLAN.md PROGRESS.md specs/00-conventions.md .claude/skills/tdd/SKILL.md ralph/ITERATION-ZERO.md"
  while IFS= read -r ref; do
    case " ${listed} " in *" ${ref} "*) continue;; esac
    [[ "${ref}" == specs/* ]] && continue
    echo "hot-path: ralph/PROMPT.md names ${ref} as a start-of-iteration read but it has no budget here" >&2; fail=1
  done < <(awk '/^## Iteration/{f=1} /^2\. /{f=0} f' ralph/PROMPT.md | grep -oE '`[A-Za-z0-9_./-]+\.md`' | tr -d '`' | sort -u)
fi
(( print )) && printf '%-40s %6d / %-6d\n' "TOTAL (with largest spec)" "$total" 13000
(( total > 13000 )) && { echo "hot-path: total ${total} tokens, budget 13000" >&2; fail=1; }
if (( fail )); then echo "hot-path: OVER BUDGET" >&2; exit 1; fi
echo "hot-path: within budget (${total} tokens with the largest spec)"
