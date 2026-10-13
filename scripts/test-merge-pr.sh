#!/usr/bin/env bash
# Behavioural tests for merge-pr.sh's branch gating — the last check before an
# iteration lands on the default branch.
#
# The case that matters most is the NEGATIVE one. merge-pr.sh exempts
# `ralph/iteration-zero` from `assert-complete` because iteration zero is a
# pipeline dry-run with no gates by construction. An exemption keyed on a
# branch NAME would be a hole: anyone can name a branch. So the exemption also
# requires the diff against the base to be empty, and the test that proves the
# hole is closed is "iteration-zero carrying a change is still refused". A
# suite that only asserted the happy path would pass against a bypass.
#
# No network: curl is stubbed on PATH and the credential helper is faked, so
# the merge call is observed rather than made.
#
# Run: scripts/test-merge-pr.sh   (exit 0 = all assertions passed)
set -uo pipefail

KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0
root="$(mktemp -d)"
mkdir -p "${root}/fakehome"
trap 'rm -rf "${root}"' EXIT

mkdir -p "${root}/bin"
# The stub replays a file rather than a fixed string, so a scenario can hand
# merge-pr.sh an API response other than success — a redirect, say — without a
# second stub on a second PATH. api_says() sets it; it resets to success after
# each scenario that changes it, so a leaked response cannot silently turn a
# later assertion into a different test than the one it claims to be.
api_says() { printf '%s\n' "$1" > "${root}/curl-response"; }
api_says '{"merged":true,"sha":"deadbeef"}'
# The CI-green precondition GETs the PR first; pr_says() stages that answer
# (a queue: one line per call, last line repeats), default clean.
pr_says() { printf '%s\n' "$@" > "${root}/pr-response"; }
pr_says '{"mergeable_state":"clean"}'
cat > "${root}/bin/curl" <<STUB
#!/usr/bin/env bash
# The PR GET and the merge PUT both land here; tell them apart by the verb.
case " \$* " in
  *" -X PUT "*) cat "${root}/curl-response" ;;
  *) line="\$(head -1 "${root}/pr-response")"; [ "\$(wc -l < "${root}/pr-response")" -gt 1 ] && sed -i 1d "${root}/pr-response"; printf '%s\n' "\$line" ;;
esac
STUB
export MERGE_PR_POLL_SLEEP=0
chmod +x "${root}/bin/curl"

# usage: scenario <name>  → prints a fresh repo path on the given branch state
new_repo() {
  # Separate statements, not `local a=$1 b=${root}/$a`: bash expands every word
  # of a `local` before assigning any of them, so the second would read an
  # unset name and silently yield a path outside the fixture.
  local name="$1"
  local dir="${root}/${name}"
  mkdir -p "${dir}"
  git init -q --bare "${dir}/remote.git"
  git init -q "${dir}/repo"
  (
    cd "${dir}/repo"
    git config user.email t@example.test
    git config user.name tester
    # BOTH fields. A helper that returns only a password leaves git still
    # wanting a username, so it falls through to whatever credential store the
    # developer's HOME provides — the suite then passes by reading real
    # credentials instead of the fixture, and fails on a runner that has none.
    # (Caught by CI 2026-09-03; green locally for exactly that wrong reason.)
    git config credential.helper '!f() { echo "username=fixture"; echo "password=faketoken"; }; f'
    git remote add origin "${dir}/remote.git"
    git commit -q --allow-empty -m "init"
    git branch -M main
    git push -q origin main
    git remote set-head origin main
  )
  echo "${dir}/repo"
}

# usage: run <description> <expected-exit> <expected-output-substring|-> <repo>
run() {
  local desc="$1" want_exit="$2" want_text="$3" repo="$4"
  local out status
  # Guard: a fixture that failed to build would otherwise run merge-pr.sh in
  # whatever directory the suite happens to sit in — which is a real repo, and
  # would report greens that describe the wrong tree entirely.
  if [[ -z "${repo}" || ! -d "${repo}/.git" ]]; then
    fail=$((fail + 1)); echo "  FAIL — ${desc}"
    echo "         fixture repo was not created: '${repo}'"
    return
  fi
  # HOME is redirected and prompting disabled so the fixture is the ONLY source
  # of credentials and config. Without this the suite silently inherits the
  # developer's ~/.git-credentials and stops testing what it claims to.
  out="$(cd "${repo}" && env HOME="${root}/fakehome" GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 PATH="${root}/bin:${PATH}" \
        bash "${KIT_SCRIPTS}/merge-pr.sh" 1 2>&1)"
  status=$?
  if [[ "${status}" -eq "${want_exit}" ]] && { [[ "${want_text}" == '-' ]] || [[ "${out}" == *"${want_text}"* ]]; }; then
    pass=$((pass + 1)); echo "  ok  — ${desc}"
  else
    fail=$((fail + 1)); echo "  FAIL — ${desc}"
    echo "         want exit ${want_exit}, output containing '${want_text}'"
    echo "         got  exit ${status}: ${out}"
  fi
}

# The negative form of `run`. Needed because a hint that fires on every failure
# is worse than no hint: "output contains X" can never catch it.
run_without() { # <description> <expected-exit> <forbidden-substring> <repo>
  local desc="$1" want_exit="$2" forbidden="$3" repo="$4"
  local out status
  if [[ -z "${repo}" || ! -d "${repo}/.git" ]]; then
    fail=$((fail + 1)); echo "  FAIL — ${desc}"
    echo "         fixture repo was not created: '${repo}'"
    return
  fi
  out="$(cd "${repo}" && env HOME="${root}/fakehome" GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 PATH="${root}/bin:${PATH}" \
        bash "${KIT_SCRIPTS}/merge-pr.sh" 1 2>&1)"
  status=$?
  if [[ "${status}" -eq "${want_exit}" ]] && [[ "${out}" != *"${forbidden}"* ]]; then
    pass=$((pass + 1)); echo "  ok  — ${desc}"
  else
    fail=$((fail + 1)); echo "  FAIL — ${desc}"
    echo "         want exit ${want_exit}, output NOT containing '${forbidden}'"
    echo "         got  exit ${status}: ${out}"
  fi
}

echo "merge-pr.sh branch gating"

# 1. The exemption itself: an empty iteration-zero branch merges.
r="$(new_repo empty-izero)"
( cd "$r" && git checkout -qb ralph/iteration-zero \
  && git commit -q --allow-empty -m "chore: ralph pipeline validation (iteration zero)" )
run "empty ralph/iteration-zero merges — the dry run is not gated" \
  0 "gates not applicable" "$r"

# 2. THE CONTROL. Same blessed name, one changed line: must still be refused.
#    If this passes-as-merge, the exemption is a way onto main without gates.
r="$(new_repo dirty-izero)"
( cd "$r" && git checkout -qb ralph/iteration-zero \
  && echo "smuggled" > payload.txt && git add payload.txt \
  && git commit -q -m "chore: ralph pipeline validation (iteration zero)" )
run "ralph/iteration-zero carrying a change is STILL gated — name is not the key" \
  1 "gates not accounted for" "$r"

# 3. An ordinary spec branch with no markers is refused.
r="$(new_repo spec-branch)"
( cd "$r" && git checkout -qb ralph/01-thing \
  && echo x > f.txt && git add f.txt && git commit -q -m "feat: thing" )
run "ralph/NN-* with no gate markers is refused" \
  1 "gates not accounted for" "$r"

# 4. Branches outside the loop's doctrine merge unimpeded.
r="$(new_repo non-ralph)"
( cd "$r" && git checkout -qb chore/unrelated \
  && echo x > f.txt && git add f.txt && git commit -q -m "chore: unrelated" )
run "a non-ralph branch is not subject to the loop's gate doctrine" \
  0 "merged PR #1" "$r"

# 5. A renamed repo. GitHub answers the merge PUT with a 301, and the redirect
#    is deliberately not followed — following it would merge into a repo whose
#    identity no longer matches the origin the slug came from. So the only
#    thing standing between a rename and a baffled human is this message.
#    (Hit for real on 2026-09-04 renaming wreck-it-ralf → wreck-it-ralph: the
#    merge died with a bare "Moved Permanently" and nothing to act on.)
r="$(new_repo renamed-remote)"
( cd "$r" && git checkout -qb chore/unrelated \
  && echo x > f.txt && git add f.txt && git commit -q -m "chore: unrelated" )
api_says '{"message":"Moved Permanently","url":"https://api.github.com/repositories/999/pulls/1/merge"}'
run "a renamed repo names the cause and the fix, not just 'Moved Permanently'" \
  1 "git remote set-url" "$r"

# THE CONTROL for that special case. An ordinary refusal must still surface its
# own message: a hint that fires on every failure is worse than none, because
# it sends people to repoint a remote that was never wrong.
r="$(new_repo ordinary-refusal)"
( cd "$r" && git checkout -qb chore/unrelated \
  && echo x > f.txt && git add f.txt && git commit -q -m "chore: unrelated" )
api_says '{"message":"Pull Request is not mergeable"}'
run "CONTROL: an ordinary API refusal is reported verbatim" \
  1 "Pull Request is not mergeable" "$r"
run_without "CONTROL: an ordinary API refusal does NOT suggest repointing origin" \
  1 "git remote set-url" "$r"
api_says '{"merged":true,"sha":"deadbeef"}'

# 6. No credential at all. merge-pr.sh has a message for this, but until
#    2026-09-10 it was unreachable: `git credential fill` exits 128 on a box
#    with no helper (prompts disabled), and under `set -e` + `pipefail` that
#    killed the script before the emptiness check ran. The caller got git's raw
#    "could not read Username" instead — which points at git configuration
#    rather than at the missing PAT, and is the wrong thing to go and fix.
#    Found by the twin suite for open-pr.sh, which shares this code.
r="$(new_repo nocred)"
( cd "$r" && git checkout -qb chore/unrelated \
  && echo x > f.txt && git add f.txt && git commit -q -m "chore: unrelated" \
  && git config --unset credential.helper )
run "a missing credential is named, not reported as a git plumbing error" \
  1 "no GitHub credential" "$r"

# 7. CI must be green — GitHub's mergeable_state, not our opinion.
r="$(new_repo ci-red)"
( cd "$r" && git checkout -qb chore/unrelated \
  && echo x > f.txt && git add f.txt && git commit -q -m "chore: unrelated" )
pr_says '{"mergeable_state":"unstable"}'
run "a PR with failing checks (unstable) is refused before any merge call" \
  1 "mergeable_state is 'unstable'" "$r"
pr_says '{"mergeable_state":"dirty"}'
run "a conflicting PR (dirty) is refused" 1 "mergeable_state is 'dirty'" "$r"
pr_says '{"mergeable_state":"unknown"}' '{"mergeable_state":"unknown"}' '{"mergeable_state":"clean"}'
run "a PR still computing (unknown) is polled until clean, then merged" 0 "merged PR #1" "$r"
pr_says '{"mergeable_state":"unknown"}'
run "a PR that never leaves unknown is refused, not merged" 1 "mergeable_state is 'unknown'" "$r"
pr_says '{"mergeable_state":"clean"}'

# 8. A gated ralph/* branch whose PROGRESS.md the next preflight would refuse.
#    hot-path-check.sh ran only in preflight, and PROMPT.md step 6 writes the log
#    after the suite and the gates, so a 32-line log entry merged (claude_sandbox
#    PR #18, 2026-10-12) and the next iteration's preflight stopped the loop. The
#    gates are stubbed here, not faked: a copy of merge-pr.sh beside stub
#    gate-marker/drift-check/progress-sync and the real hot-path-check.sh.
mkdir -p "${root}/kit"
cp "${KIT_SCRIPTS}/merge-pr.sh" "${KIT_SCRIPTS}/hot-path-check.sh" "${root}/kit/"
for s in gate-marker.sh drift-check.sh progress-sync.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "${root}/kit/${s}"; chmod +x "${root}/kit/${s}"
done
gated_run() { # <description> <expected-exit> <expected-output-substring> <repo>
  local out status
  out="$(cd "$4" && env HOME="${root}/fakehome" GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 PATH="${root}/bin:${PATH}" \
        bash "${root}/kit/merge-pr.sh" 1 2>&1)"
  status=$?
  if [[ "${status}" -eq "$2" && "${out}" == *"$3"* ]]; then
    pass=$((pass + 1)); echo "  ok  — $1"
  else
    fail=$((fail + 1)); echo "  FAIL — $1"
    echo "         want exit $2, output containing '$3'"
    echo "         got  exit ${status}: ${out}"
  fi
}
progress_with_entry() { # <log-entry-body-lines>
  printf '# Progress\n\n| Spec | Status | Notes |\n|---|---|---|\n| 01-x | in-progress (slice 1/1) | |\n\n## Log\n\n### 2026-10-12 — spec 01-x\n\n'
  for ((i = 1; i <= $1; i++)); do echo "line ${i}"; done
}
r="$(new_repo hot-path-over)"
( cd "$r" && git checkout -qb ralph/01-x \
  && progress_with_entry 30 > PROGRESS.md && git add PROGRESS.md && git commit -q -m "feat(01): x" )
gated_run "a gated ralph/* branch whose PROGRESS.md log entry is over 25 lines is refused" \
  1 "hot-path-check.sh not cleared" "$r"
r="$(new_repo hot-path-within)"
( cd "$r" && git checkout -qb ralph/01-x \
  && progress_with_entry 20 > PROGRESS.md && git add PROGRESS.md && git commit -q -m "feat(01): x" )
gated_run "CONTROL: the same branch with a 20-line entry merges" 0 "merged PR #1" "$r"

echo
echo "  ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
