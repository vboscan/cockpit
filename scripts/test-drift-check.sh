#!/usr/bin/env bash
# Behavioural tests for drift-check.sh (was test-drift; renamed so CI's test-*.sh glob does not run the checker as a test).
# Run: scripts/test-drift-check.sh   (exit 0 = all assertions passed)
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0; root="$(mktemp -d)"; trap 'rm -rf "${root}"' EXIT

new_repo() { # → path; on branch ralph/01-x off main, origin present
  local d="${root}/$1"; mkdir -p "${d}"; git init -q --bare "${d}/remote.git"; git init -q "${d}/repo"
  ( cd "${d}/repo" && git config user.email t@example.test && git config user.name t \
    && git remote add origin "${d}/remote.git" \
    && printf 'package p\n' > p.go && git add -A && git commit -qm init && git branch -M main \
    && git push -q origin main && git remote set-head origin main && git checkout -qb ralph/01-x )
  echo "${d}/repo"
}
c() { git -C "$1" add -A; git -C "$1" commit -q -m "$2" ${3:+-m "$3"}; }
run() { # <desc> <want-exit> <want-substring|-> <repo>
  local out st; out="$(cd "$4" && bash "${KIT_SCRIPTS}/drift-check.sh" 2>&1)"; st=$?
  if [[ $st -eq $2 ]] && { [[ "$3" == '-' ]] || [[ "$out" == *"$3"* ]]; }; then pass=$((pass+1)); echo "  ok  — $1"
  else fail=$((fail+1)); echo "  FAIL — $1"; echo "         want exit $2 containing '$3'; got $st: $out"; fi
}
red_test() { printf 'package p\nimport "testing"\nfunc TestAC1_Thing(t *testing.T) { if Thing() != 1 { t.Fatal("x") } }\nfunc TestAC2_Other(t *testing.T) { if Other() != 2 { t.Fatal("y") } }\n' > "$1/p_test.go"; }
stub()     { printf 'package p\nfunc Thing() int { return 0 }\nfunc Other() int { return 0 }\n' > "$1/p.go"; }
impl()     { printf 'package p\nfunc Thing() int { return 1 }\nfunc Other() int { return 2 }\n' > "$1/p.go"; }

echo "drift-check.sh"
r="$(new_repo nored)"; red_test "$r"; stub "$r"; c "$r" "wip"; impl "$r"; c "$r" "checkpoint(green): 01 s1"
run "no checkpoint(red) → not cleared" 1 "no checkpoint(red)" "$r"

r="$(new_repo clean)"; red_test "$r"; stub "$r"; c "$r" "checkpoint(red): 01 s1"; impl "$r"
printf 'package p\nimport "testing"\nfunc TestAC3_New(t *testing.T) {}\n' > "$r/q_test.go"; c "$r" "checkpoint(green): 01 s1"
run "additions only → cleared" 0 "0 unexplained" "$r"

r="$(new_repo drift)"; red_test "$r"; stub "$r"; c "$r" "checkpoint(red): 01 s1"; impl "$r"
sed -i 's/!= 1/!= 0/' "$r/p_test.go"; c "$r" "checkpoint(green): 01 s1"
run "a modified red test without a trailer → DRIFT, not cleared" 1 "DRIFT    p_test.go: TestAC1_Thing" "$r"

r="$(new_repo amended)"; red_test "$r"; stub "$r"; c "$r" "checkpoint(red): 01 s1"; impl "$r"
sed -i 's/!= 1/!= 1 \/\/ seam/' "$r/p_test.go"; c "$r" "fix: seam" "Test-Amendment: TestAC1_Thing — seam renamed; assertion unchanged"; git -C "$r" commit -q --allow-empty -m "checkpoint(green): 01 s1"
run "a modified red test WITH a trailer naming it → amended, cleared" 0 "amended  p_test.go: TestAC1_Thing" "$r"

r="$(new_repo deleted)"; red_test "$r"; stub "$r"; c "$r" "checkpoint(red): 01 s1"; impl "$r"
sed -i '/TestAC2_Other/d' "$r/p_test.go"; c "$r" "checkpoint(green): 01 s1"
run "a deleted red test without a trailer → not cleared" 1 "DRIFT" "$r"

r="$(new_repo order)"; red_test "$r"; { echo 'package p'; for i in $(seq 1 70); do echo "func F$i() int { return $i }"; done; echo 'func Thing() int { return 1 }'; echo 'func Other() int { return 2 }'; } > "$r/p.go"; c "$r" "checkpoint(red): 01 s1"
git -C "$r" commit -q --allow-empty -m "checkpoint(green): 01 s1"
run "70 lines of implementation before red → ORDER violation" 1 "ORDER" "$r"

r="$(new_repo stubok)"; red_test "$r"; stub "$r"; c "$r" "checkpoint(red): 01 s1"; impl "$r"; c "$r" "checkpoint(green): 01 s1"
run "a small stub before red is fine" 0 "cleared" "$r"

# Python (pytest): test_*.py / *_test.py anywhere are tests; `def test_*` names a drifted test.
py_red() { mkdir -p "$1/tests/unit"; { echo 'from p import thing, other'; for i in $(seq 1 70); do echo "# filler $i"; done
  printf 'def test_ac1_thing() -> None:\n    assert thing() == 1\n\n\ndef test_ac2_other() -> None:\n    assert other() == 2\n'; } > "$1/tests/unit/test_p.py"; }
r="$(new_repo pyorder)"; py_red "$r"; stub "$r"; c "$r" "checkpoint(red): 01 s1"; impl "$r"; c "$r" "checkpoint(green): 01 s1"
run "a long Python red test under tests/ is a test, not implementation" 0 "cleared" "$r"

r="$(new_repo pydrift)"; py_red "$r"; stub "$r"; c "$r" "checkpoint(red): 01 s1"; impl "$r"
sed -i 's/thing() == 1/thing() == 0/' "$r/tests/unit/test_p.py"; c "$r" "checkpoint(green): 01 s1"
run "a modified Python red test without a trailer → DRIFT naming the function" 1 "DRIFT    tests/unit/test_p.py: test_ac1_thing" "$r"

r="$(new_repo pysuffix)"; mkdir -p "$r/pkg"; printf 'def test_a() -> None:\n    assert True\n' > "$r/pkg/p_test.py"; stub "$r"; c "$r" "checkpoint(red): 01 s1"
sed -i 's/True/False/' "$r/pkg/p_test.py"; c "$r" "checkpoint(green): 01 s1"
run "*_test.py is a test file too" 1 "DRIFT    pkg/p_test.py: test_a" "$r"

# Shell: scripts/test-*.sh, *_test.sh and *.bats anywhere are tests. A shell
# suite is one script per subject, so the red file is routinely far past the
# stub limit — counted as implementation, every shell project's first merge
# would be refused on ORDER (claude_sandbox PR #14, 2026-10-11). A drifted case
# is named by the nearest `run "…"` / `@test "…"` / `test_*()` line above it.
sh_red() { mkdir -p "$1/scripts"; { printf '#!/usr/bin/env bash\nrun() { :; }\n'; for i in $(seq 1 70); do echo "# padding $i"; done
  printf 'run "AC1 thing is one" thing 1\nrun "AC2 other is two" other 2\n'; } > "$1/scripts/test-p.sh"; }
r="$(new_repo shorder)"; sh_red "$r"; stub "$r"; c "$r" "checkpoint(red): 01 s1"; impl "$r"; c "$r" "checkpoint(green): 01 s1"
run "a 70+ line scripts/test-*.sh before red is a test, not ORDER" 0 "cleared" "$r"

r="$(new_repo shdrift)"; sh_red "$r"; stub "$r"; c "$r" "checkpoint(red): 01 s1"; impl "$r"
sed -i 's/thing 1/thing 0/' "$r/scripts/test-p.sh"; c "$r" "checkpoint(green): 01 s1"
run "a modified shell red case without a trailer → DRIFT naming the case" 1 'DRIFT    scripts/test-p.sh: AC1 thing is one' "$r"

r="$(new_repo bats)"; mkdir -p "$r/t"; printf '@test "adds" {\n  run "$BATS_TEST_DIRNAME/add" 1 1\n  [ "$output" = 2 ]\n}\n' > "$r/t/add.bats"; stub "$r"; c "$r" "checkpoint(red): 01 s1"
sed -i 's/= 2/= 3/' "$r/t/add.bats"; c "$r" "checkpoint(green): 01 s1"
run "*.bats is a test file; @test names the case, not the indented bats run" 1 'DRIFT    t/add.bats: adds' "$r"

r="$(new_repo shfunc)"; printf 'test_sum() {\n  [ "$(sum 1 1)" = 2 ]\n}\nfunction test_neg {\n  [ "$(sum 1 -1)" = 0 ]\n}\n' > "$r/sum_test.sh"; stub "$r"; c "$r" "checkpoint(red): 01 s1"
sed -i 's/= 2/= 3/; s/= 0/= 9/' "$r/sum_test.sh"; c "$r" "checkpoint(green): 01 s1"
run "*_test.sh is a test file; test_*() names the case" 1 'DRIFT    sum_test.sh: test_sum' "$r"
run "a \`function test_*\` without parentheses is named too" 1 'DRIFT    sum_test.sh: test_neg' "$r"

r="$(new_repo shroot)"; printf 'test_a() { [ 1 = 1 ]; }\n' > "$r/test_a.sh"; printf 'test_b() { [ 1 = 1 ]; }\n' > "$r/test-b.sh"; mkdir -p "$r/t"; printf 'test_c() { [ 1 = 1 ]; }\n' > "$r/t/test_c.sh"; stub "$r"; c "$r" "checkpoint(red): 01 s1"
sed -i 's/1 = 1/1 = 2/' "$r/test_a.sh" "$r/test-b.sh" "$r/t/test_c.sh"; c "$r" "checkpoint(green): 01 s1"
run "root-level test_*.sh is a test file" 1 'DRIFT    test_a.sh: test_a' "$r"
run "root-level test-*.sh is a test file" 1 'DRIFT    test-b.sh: test_b' "$r"
run "nested test_*.sh is a test file" 1 'DRIFT    t/test_c.sh: test_c' "$r"

echo "  ${pass} passed, ${fail} failed"; [[ $fail -eq 0 ]]
