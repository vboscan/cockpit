#!/usr/bin/env bash
# Tests written at checkpoint(red) must reach checkpoint(green) unchanged, or
# say why. (README: "Red is written independently".)
#
# usage: scripts/drift-check.sh            # exit 0 = clean, 1 = drift or order violation, 2 = usage
#
# Three facts decided from git alone, never from what a session says:
#
#   1. ORDER. checkpoint(red) must exist on this branch, and no implementation
#      may precede it. Non-test, non-doc files changed between the branch
#      point and red are stubs by definition; a "stub" adding more than
#      $RALPH_STUB_MAX_LINES lines (default 60) is implementation before red.
#   2. DRIFT. Any test function that existed at red and was modified or deleted
#      by green is drift. Additions (new test functions, new files) are not.
#   3. TRAILERS. Every drifted test must be named by a `Test-Amendment:` git
#      trailer in a commit between red and HEAD, e.g.
#        Test-Amendment: TestAC3_TakeoverOnTimeout — seam changed to Apply([][]byte); assertion unchanged
#      The trailer is matched on the test function name or the file basename.
#      A shell case is named by the nearest `run "…"` (column 0: inside a bats
#      body `run` is a command, and the `@test "…"` above it is the name),
#      `@test "…"` or `test_*()` line above the change. A harness-style suite
#      puts a case's setup before its `run` line, so a change there is named
#      for the case above it or `?`: for a shell suite, name the file.
#
# No red checkpoint, no branch point, or an unparseable diff all fail closed:
# doubt costs a look, never coverage. merge-pr.sh runs this on ralph/* after
# gate-marker.sh assert-complete; the spec-fidelity gate is handed its output.
set -uo pipefail

STUB_MAX="${RALPH_STUB_MAX_LINES:-60}"
TEST_GLOBS=('*_test.go' '*.test.ts' '*.spec.ts' 'test_*.py' '*/test_*.py' '*_test.py' 'test-*.sh' '*/test-*.sh' 'test_*.sh' '*/test_*.sh' '*_test.sh' '*.bats')
is_test() { case "$1" in *_test.go|*.test.ts|*.spec.ts|test_*.py|*/test_*.py|*_test.py|test-*.sh|*/test-*.sh|test_*.sh|*/test_*.sh|*_test.sh|*.bats) return 0;; *) return 1;; esac; }
is_doc()  { case "$1" in *.md|specs/*|docs/*|PROGRESS.md|runs/*) return 0;; *) return 1;; esac; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "drift-check: not a git work tree" >&2; exit 2; }

base_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
git rev-parse --verify --quiet "${base_ref}" >/dev/null || base_ref="main"
base="$(git merge-base "${base_ref}" HEAD 2>/dev/null)"
[[ -n "${base}" ]] || { echo "drift-check: NOT cleared — no branch point against ${base_ref}" >&2; exit 1; }

# Newest red, and the newest green after it (else HEAD).
red=""; green=""
while IFS=$'\t' read -r sha subj; do
  if [[ -z "${red}" && "${subj}" == "checkpoint(red)"* ]]; then red="${sha}"; break; fi
  [[ -z "${green}" && "${subj}" == "checkpoint(green)"* ]] && green="${sha}"
done < <(git log --format='%H%x09%s' "${base}..HEAD")
if [[ -z "${red}" ]]; then
  echo "drift-check: NOT cleared — no checkpoint(red) on this branch (ralph/PROMPT.md step 3)." >&2
  exit 1
fi
[[ -n "${green}" ]] || green="HEAD"

fail=0

# 1. ORDER
while IFS=$'\t' read -r added removed path; do
  [[ -n "${path}" ]] || continue
  is_test "${path}" && continue
  is_doc  "${path}" && continue
  [[ "${added}" == "-" ]] && continue   # binary
  if (( added > STUB_MAX )); then
    echo "drift-check: ORDER — ${path} added ${added} lines before checkpoint(red) (stub limit ${STUB_MAX}): implementation preceded the tests" >&2
    fail=1
  fi
done < <(git diff --numstat "${base}" "${red}")

# 2. DRIFT — test functions that existed at red and changed by green
declare -a drift_names=() drift_files=()
current=""
while IFS= read -r line; do
  case "${line}" in
    "--- /dev/null") current="__new__" ;;
    "--- a/"*) current="${line#--- a/}" ;;
    "+++ "*) ;;
    "@@ "*)
      [[ "${current}" == "__new__" || -z "${current}" ]] && continue
      # @@ -a,b +c,d @@ — b>0 means lines existed at red here and were touched.
      hdr="${line#@@ -}"; old="${hdr%% *}"; a="${old%%,*}"; b="${old#*,}"; [[ "${old}" == *,* ]] || b=1
      (( b > 0 )) || continue
      name="$(git show "${red}:${current}" 2>/dev/null | awk -v n="${a}" '
        NR<=n && /^func Test[A-Za-z0-9_]*/ { sub(/\(.*/, "", $2); name=$2 }
        NR<=n && /^[[:space:]]*(async[[:space:]]+)?def test_[A-Za-z0-9_]*/ { match($0, /test_[A-Za-z0-9_]*/); name=substr($0, RSTART, RLENGTH) }
        NR<=n && /^[[:space:]]*(it|test)\(["'"'"']/ { match($0, /["'"'"'][^"'"'"']*["'"'"']/); name=substr($0, RSTART+1, RLENGTH-2) }
        NR<=n && /^(run|[[:space:]]*@test)[[:space:]]+["'"'"']/ { match($0, /["'"'"'][^"'"'"']*["'"'"']/); name=substr($0, RSTART+1, RLENGTH-2) }
        NR<=n && /^[[:space:]]*(function[[:space:]]+)?test_[A-Za-z0-9_]*[[:space:]]*(\(\)|\{)/ { match($0, /test_[A-Za-z0-9_]*/); name=substr($0, RSTART, RLENGTH) }
        END { print name }')"
      drift_names+=("${name:-?}"); drift_files+=("${current}")
      ;;
  esac
done < <(git diff --unified=0 "${red}" "${green}" -- "${TEST_GLOBS[@]}")

# 3. TRAILERS
trailers="$(git log --format=%B "${red}..HEAD" | grep -E '^Test-Amendment:' || true)"
if (( ${#drift_names[@]} > 0 )); then
  echo "drift-check: tests modified or deleted between checkpoint(red) ${red:0:12} and ${green:0:12}:"
  for i in "${!drift_names[@]}"; do
    n="${drift_names[$i]}"; f="${drift_files[$i]}"; b="$(basename "${f}")"
    if [[ -n "${trailers}" ]] && { [[ "${n}" != "?" && "${trailers}" == *"${n}"* ]] || [[ "${trailers}" == *"${b}"* ]]; }; then
      echo "  amended  ${f}: ${n}  (Test-Amendment trailer present)"
    else
      echo "  DRIFT    ${f}: ${n}  — no Test-Amendment trailer names it" ; fail=1
    fi
  done
  echo "  Review question for the spec-fidelity gate: does each amended test still prove its criterion?"
fi

if (( fail )); then echo "drift-check: NOT cleared" >&2; exit 1; fi
echo "drift-check: cleared — red ${red:0:12} → green ${green:0:12}: ${#drift_names[@]} amended, 0 unexplained"
exit 0
