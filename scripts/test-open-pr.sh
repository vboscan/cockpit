#!/usr/bin/env bash
# Behavioural tests for open-pr.sh.
#
# Two properties carry the weight here, and both are about NOT producing a
# number that looks like a fact:
#
#   * The resume case. An iteration that dies between opening the PR and
#     committing the PROGRESS.md entry gets picked up again, and the second
#     call must return the SAME number. GitHub's duplicate-POST 422 carries no
#     number, so it is looked up — and the control for that is the lookup
#     coming back empty, which must FAIL rather than invent one. ralph/PROMPT.md
#     step 6 exists because a guessed PR number is indistinguishable from a
#     recorded fact once committed.
#
#   * The tree the PR describes. A PR opened for an unpushed or half-pushed
#     branch opens successfully and describes work the session never gated.
#     Nothing downstream catches that, so it is caught here, before any API
#     call — and the assertion is that no call was made, not merely that the
#     exit code was non-zero.
#
# Also pinned: open-pr.sh must NOT assert gate markers. Step 6 opens the PR
# before the `confirm` marker is recorded, so gating here would deadlock the
# tail order. That is easy to "fix" by someone reading merge-pr.sh alongside
# it, so a test stands on it.
#
# No network: curl is stubbed on PATH and the credential helper is faked, so
# the API calls are observed rather than made.
#
# Run: scripts/test-open-pr.sh   (exit 0 = all assertions passed)
set -uo pipefail

KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0
fail=0
root="$(mktemp -d)"
mkdir -p "${root}/fakehome" "${root}/bin"
trap 'rm -rf "${root}"' EXIT

# The stub replays staged files and records what it was asked to do, so a
# scenario can assert on the payload and on whether a call happened at all.
post_says() { printf '%s\n' "$1" > "${root}/curl-post"; }
get_says()  { printf '%s\n' "$1" > "${root}/curl-get";  }
post_says '{"number":7,"html_url":"https://github.com/o/r/pull/7"}'
get_says  '[]'

cat > "${root}/bin/curl" <<STUB
#!/usr/bin/env bash
# Record the invocation, then replay whatever the scenario staged. The POST and
# the duplicate-lookup GET are told apart by their own flags, so a scenario can
# stage a different answer for each.
mode=post
prev=""
for a in "\$@"; do
  [ "\$a" = "-G" ] && mode=get
  [ "\$prev" = "-d" ] && printf '%s' "\$a" > "${root}/last-payload"
  prev="\$a"
done
echo "\$mode" >> "${root}/calls"
cat "${root}/curl-\$mode"
STUB
chmod +x "${root}/bin/curl"

reset_calls() { : > "${root}/calls"; rm -f "${root}/last-payload"; }

new_repo() { # <name> → prints a fresh repo path with origin and a main branch
  local name="$1"
  local dir="${root}/${name}"
  mkdir -p "${dir}"
  git init -q --bare "${dir}/remote.git"
  git init -q "${dir}/repo"
  (
    cd "${dir}/repo"
    git config user.email t@example.test
    git config user.name tester
    # BOTH fields — a helper returning only a password leaves git still wanting
    # a username and falling through to the developer's real credential store,
    # which is how a suite passes for the wrong reason and dies on a runner.
    git config credential.helper '!f() { echo "username=fixture"; echo "password=faketoken"; }; f'
    git remote add origin "${dir}/remote.git"
    git commit -q --allow-empty -m "init"
    git branch -M main
    git push -q origin main
    git remote set-head origin main
  )
  echo "${dir}/repo"
}

run() { # <description> <expected-exit> <expected-substring|-> <repo> [args...]
  local desc="$1" want_exit="$2" want_text="$3" repo="$4"; shift 4
  local out status
  if [[ -z "${repo}" || ! -d "${repo}/.git" ]]; then
    fail=$((fail + 1)); echo "  FAIL — ${desc}"
    echo "         fixture repo was not created: '${repo}'"
    return
  fi
  # HOME redirected and prompting disabled so the fixture is the ONLY source of
  # credentials and config.
  out="$(cd "${repo}" && env HOME="${root}/fakehome" GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 PATH="${root}/bin:${PATH}" \
        bash "${KIT_SCRIPTS}/open-pr.sh" "$@" 2>&1)"
  status=$?
  if [[ "${status}" -eq "${want_exit}" ]] && { [[ "${want_text}" == '-' ]] || [[ "${out}" == *"${want_text}"* ]]; }; then
    pass=$((pass + 1)); echo "  ok  — ${desc}"
  else
    fail=$((fail + 1)); echo "  FAIL — ${desc}"
    echo "         want exit ${want_exit}, output containing '${want_text}'"
    echo "         got  exit ${status}: ${out}"
  fi
}

run_without() { # <description> <expected-exit> <forbidden> <repo> [args...]
  local desc="$1" want_exit="$2" forbidden="$3" repo="$4"; shift 4
  local out status
  out="$(cd "${repo}" && env HOME="${root}/fakehome" GIT_CONFIG_NOSYSTEM=1 \
        GIT_TERMINAL_PROMPT=0 PATH="${root}/bin:${PATH}" \
        bash "${KIT_SCRIPTS}/open-pr.sh" "$@" 2>&1)"
  status=$?
  if [[ "${status}" -eq "${want_exit}" ]] && [[ "${out}" != *"${forbidden}"* ]]; then
    pass=$((pass + 1)); echo "  ok  — ${desc}"
  else
    fail=$((fail + 1)); echo "  FAIL — ${desc}"
    echo "         want exit ${want_exit}, output NOT containing '${forbidden}'"
    echo "         got  exit ${status}: ${out}"
  fi
}

check() { # <description> <condition-description> <actual> <expected>
  local desc="$1" actual="$3" expected="$4"
  if [[ "${actual}" == "${expected}" ]]; then
    pass=$((pass + 1)); echo "  ok  — ${desc}"
  else
    fail=$((fail + 1)); echo "  FAIL — ${desc}"
    echo "         want $2: '${expected}'"
    echo "         got:        '${actual}'"
  fi
}

branch_at() { # <repo> <branch>  → branch, commit, push
  ( cd "$1" && git checkout -qb "$2" && echo x > f.txt && git add f.txt \
    && git commit -q -m "feat: thing" && git push -q -u origin "$2" )
}

echo "open-pr.sh"

# 1. Happy path.
r="$(new_repo happy)"; branch_at "$r" feat/thing
reset_calls
run "an opened PR reports its real number and URL" \
  0 "opened PR #7" "$r" --title "feat: thing"

# 2. The payload is JSON, not string interpolation. A body carrying quotes,
#    newlines and backslashes is where naive `-d '{"body":"'"$body"'"}'` breaks:
#    it either fails to parse or parses into something other than what was
#    written, and the PR body is how a human reviews the iteration.
r="$(new_repo hazard)"; branch_at "$r" feat/hazard
printf 'line "one"\nback\\slash and `ticks`\n\ttab\n' > "${root}/body.md"
reset_calls
run "a body with quotes, newlines and backslashes still opens" \
  0 "opened PR #7" "$r" --title 'feat: "quoted" \ title' --body-file "${root}/body.md"
got_body="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["body"], end="")' "${root}/last-payload" 2>&1)"
check "the body arrives at the API byte-for-byte" "body" \
  "${got_body}" "$(cat "${root}/body.md")"
got_title="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"], end="")' "${root}/last-payload" 2>&1)"
check "the title arrives at the API byte-for-byte" "title" \
  "${got_title}" 'feat: "quoted" \ title'

# 3. THE RESUME CASE. A duplicate POST must yield the number that already
#    exists, not an error and not a second PR.
r="$(new_repo resume)"; branch_at "$r" feat/resume
post_says '{"message":"Validation Failed","errors":[{"resource":"PullRequest","message":"A pull request already exists for fixture:feat/resume."}]}'
get_says  '[{"number":12,"html_url":"https://github.com/o/r/pull/12"}]'
reset_calls
run "a duplicate open returns the EXISTING number, so a resumed iteration records the same PR" \
  0 "PR #12 already open" "$r" --title "feat: resume"

# 4. THE CONTROL for the resume case. If the lookup finds nothing, the state is
#    ambiguous and the only safe answer is failure. A script that printed a
#    number here would be manufacturing exactly the false fact that "never a
#    predicted number" was written to prevent.
r="$(new_repo resume-empty)"; branch_at "$r" feat/resume-empty
get_says '[]'
reset_calls
run "CONTROL: 'already exists' with no PR found fails loudly" \
  1 "no open PR was found" "$r" --title "feat: resume-empty"
run_without "CONTROL: that failure never prints a PR number" \
  1 "PR #" "$r" --title "feat: resume-empty"
post_says '{"number":7,"html_url":"https://github.com/o/r/pull/7"}'
get_says  '[]'

# 5. An unpushed branch. The PR would describe a tree that was never gated.
r="$(new_repo unpushed)"
( cd "$r" && git checkout -qb feat/unpushed && echo x > f.txt \
  && git add f.txt && git commit -q -m "feat: unpushed" )
reset_calls
run "an unpushed branch is refused, and the message says how to fix it" \
  1 "git push -u origin feat/unpushed" "$r" --title "feat: unpushed"
check "no API call is made for an unpushed branch" "call log" \
  "$(cat "${root}/calls")" ""

# 6. Pushed, then moved on. Same failure mode, and the one that actually bites:
#    the branch exists on origin, so a naive existence check passes.
r="$(new_repo stale)"; branch_at "$r" feat/stale
( cd "$r" && echo y > g.txt && git add g.txt && git commit -q -m "feat: more" )
reset_calls
run "a branch whose local tip is ahead of origin is refused" \
  1 "different tree" "$r" --title "feat: stale"
check "no API call is made for a half-pushed branch" "call log" \
  "$(cat "${root}/calls")" ""

# 7. THE NON-GATE. open-pr.sh must not assert gate markers: step 6 opens the PR
#    before `confirm` is recorded, so gating here deadlocks the tail order.
#    merge-pr.sh refuses this exact branch shape; open-pr.sh must not.
r="$(new_repo ungated)"; branch_at "$r" ralph/01-thing
reset_calls
run "a ralph/* branch with no gate markers still opens — gating belongs at merge" \
  0 "opened PR #7" "$r" --title "feat: thing"

# 8. An ordinary API refusal is reported verbatim rather than swallowed.
r="$(new_repo refused)"; branch_at "$r" feat/refused
post_says '{"message":"Validation Failed","errors":[{"resource":"PullRequest","field":"base","message":"base is invalid"}]}'
reset_calls
run "an ordinary API refusal is reported with its detail" \
  1 "base is invalid" "$r" --title "feat: refused"
run_without "CONTROL: an ordinary refusal is not mistaken for the resume case" \
  1 "already open" "$r" --title "feat: refused"
post_says '{"number":7,"html_url":"https://github.com/o/r/pull/7"}'

# 9. Argument handling.
r="$(new_repo args)"; branch_at "$r" feat/args
run "a missing --title is a usage error, not a PR titled ''" \
  2 "usage:" "$r"
run "a --body-file that does not exist is a usage error" \
  2 "does not exist" "$r" --title "feat: args" --body-file "${root}/nope.md"
run "an unknown argument is rejected rather than ignored" \
  2 "unknown argument" "$r" --title "feat: args" --draft

# 10. head == base. GitHub would refuse this too, but the message it gives is
#     about validation rather than about what the caller got wrong.
r="$(new_repo samebranch)"
( cd "$r" && git checkout -q main )
reset_calls
run "opening main against main is refused before the API is troubled" \
  1 "nothing to open a PR for" "$r" --title "feat: same"

# 11. No credential at all.
r="$(new_repo nocred)"; branch_at "$r" feat/nocred
( cd "$r" && git config --unset credential.helper )
reset_calls
run "a missing credential is named, not reported as an API failure" \
  1 "no GitHub credential" "$r" --title "feat: nocred"

echo
echo "  ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
