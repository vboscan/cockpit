#!/usr/bin/env bash
# Behavioural tests for scripts/notify.sh — the GitHub-issue transport that replaced ntfy
# on 2026-09-30. The API is exercised against a stub `curl` on PATH that records each call and
# answers from canned responses, so the tests never touch github.com. Credentials come from the
# GITHUB_TOKEN fallback (env -i, no credential helper), and the repository from GITHUB_REPOSITORY,
# because a test must not depend on the checkout's remote or the box's credential store.
#
# Run: scripts/test-notify.sh   (exit 0 = all assertions passed)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NOTIFY="${REPO_ROOT}/scripts/notify.sh"
pass=0; fail=0
work="$(mktemp -d)"; trap 'rm -rf "${work}"' EXIT

# A curl that appends its arguments to a log, consumes stdin (the -K config that
# carries the token), and prints the Nth canned response for the Nth call.
mkdir -p "${work}/bin" "${work}/home" "${work}/responses"
cat > "${work}/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
n=$(( $(cat "${CURL_COUNT}" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${CURL_COUNT}"
printf 'CALL %s: %s\n' "${n}" "$*" >> "${CURL_LOG}"
[ -f "${CURL_RESPONSES}/${n}" ] && cat "${CURL_RESPONSES}/${n}"
exit "${CURL_EXIT:-0}"
STUB
chmod +x "${work}/bin/curl"

# usage: run <description> <expected-exit> <expected-log-substring|-> [env assignments...]
run() {
  local desc="$1" want_exit="$2" want_text="$3"; shift 3
  local log="${work}/curl.log" out status
  : > "${log}"; rm -f "${work}/count"
  # RALPH_REPO_ROOT defaults to the kit checkout, whose origin is real; the work
  # dir is not a repository, so the slug falls back to GITHUB_REPOSITORY unless a
  # case sets its own root (first wins under env -i: "$@" comes last).
  out="$(env -i RALPH_REPO_ROOT="${work}" "$@" CURL_LOG="${log}" CURL_COUNT="${work}/count" CURL_RESPONSES="${work}/responses" \
        PATH="${work}/bin:${PATH}" HOME="${work}/home" GIT_TERMINAL_PROMPT=0 \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null RALPH_PROJECT_NAME=notifytest \
        "${NOTIFY}" -t 'test title' '@hello "there"' 2>&1)"
  status=$?
  local sent; sent="$(cat "${log}")"
  if [[ "${status}" -eq "${want_exit}" ]] && { [[ "${want_text}" == '-' ]] || [[ "${sent}" == *"${want_text}"* ]]; }; then
    pass=$((pass + 1)); echo "  ok  — ${desc}"
  else
    fail=$((fail + 1)); echo "  FAIL — ${desc}"
    echo "         want exit ${want_exit}, curl log containing '${want_text}'"
    echo "         got  exit ${status}; curl log: ${sent}"
    echo "         output: ${out}"
  fi
}
respond() { rm -f "${work}/responses"/*; local i=1; for r in "$@"; do printf '%s' "$r" > "${work}/responses/${i}"; i=$((i+1)); done; }
calls() { grep -c '^CALL' "${work}/curl.log"; }
expect_calls() { if [[ "$(calls)" -eq "$1" ]]; then pass=$((pass+1)); echo "  ok  — …$2"; else fail=$((fail+1)); echo "  FAIL — …$2 (got $(calls) calls)"; fi; }

echo "notify.sh behavioural tests (GitHub issue transport)"
cd "${work}"   # not a git repository: the repository must come from GITHUB_REPOSITORY

# --- a pinned issue: one POST to its comments ------------------------------
respond '{"html_url":"https://github.com/o/r/issues/42#issuecomment-1"}'
run "pinned RALPH_NOTIFY_ISSUE → one POST to that issue's comments" \
  0 'https://api.github.com/repos/o/r/issues/42/comments' GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r RALPH_NOTIFY_ISSUE=42
expect_calls 1 "in exactly one call"
if grep -q -- '-X POST' "${work}/curl.log" && grep -q 'test title' "${work}/curl.log" && grep -q '@hello' "${work}/curl.log"; then
  pass=$((pass+1)); echo "  ok  — …as a POST whose body carries title and message (leading @ included)"
else fail=$((fail+1)); echo "  FAIL — POST/body check: $(cat "${work}/curl.log")"; fi
if grep -q 'Bearer' "${work}/curl.log"; then fail=$((fail+1)); echo "  FAIL — token reached argv"; else pass=$((pass+1)); echo "  ok  — …and the token never reaches argv"; fi

# --- lookup by title: GET the open issues, then comment on the match ----------
respond '[{"number":3,"title":"other"},{"number":5,"title":"Ralph loop notifications","pull_request":{}},{"number":7,"title":"Ralph loop notifications"}]' \
        '{"html_url":"https://github.com/o/r/issues/7#issuecomment-2"}'
run "no pin → finds the open issue by title, skipping a PR with the same title" \
  0 'issues/7/comments' GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r
expect_calls 2 "in two calls (list, comment)"

# --- lookup misses: create the issue, then comment on it ---------------------
respond '[]' '{"number":9,"html_url":"https://github.com/o/r/issues/9"}' '{"html_url":"https://github.com/o/r/issues/9#issuecomment-3"}'
run "no pin, no match → creates the issue and comments on it" \
  0 'issues/9/comments' GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r
expect_calls 3 "in three calls (list, create, comment)"
if grep -q 'repos/o/r/issues -H' "${work}/curl.log"; then pass=$((pass+1)); echo "  ok  — …the create call targets the issues collection"
else fail=$((fail+1)); echo "  FAIL — create call missing: $(cat "${work}/curl.log")"; fi

# --- honours a custom title for the lookup -----------------------------------
respond '[{"number":11,"title":"loop: alerts"}]' '{"html_url":"https://github.com/o/r/issues/11#issuecomment-4"}'
run "RALPH_NOTIFY_ISSUE_TITLE selects the issue" \
  0 'issues/11/comments' GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r RALPH_NOTIFY_ISSUE_TITLE='loop: alerts'

# --- the repository is the project's, not the caller's cwd -------------------
# The operator runs notify.sh from its kit checkout (ralph-operator.sh note):
# on 2026-10-11 its incident note landed on the kit repository's issue, because
# the slug came from `git remote get-url origin` in the cwd.
git init -q "${work}/project" && git -C "${work}/project" remote add origin https://github.com/acme/project.git
git init -q "${work}/kit" && git -C "${work}/kit" remote add origin git@github.com:acme/kit.git
cd "${work}/kit" || exit 1
respond '{"html_url":"https://github.com/acme/project/issues/4#issuecomment-9"}'
run "run from another repository's checkout: the comment goes to RALPH_REPO_ROOT's origin" \
  0 'repos/acme/project/issues/4/comments' GITHUB_TOKEN=t RALPH_NOTIFY_ISSUE=4 "RALPH_REPO_ROOT=${work}/project"
cd "${work}" || exit 1

# --- failure paths: every one exits 1 so a caller can log it, and never blocks --
respond
run "no credential anywhere → exit 1" 1 '-' GITHUB_REPOSITORY=o/r
expect_calls 0 "with zero calls"
run "no repository (no remote, no GITHUB_REPOSITORY) → exit 1" 1 '-' GITHUB_TOKEN=t
respond '{"html_url":"x"}'
run "curl failure → exit 1" 1 '-' GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r RALPH_NOTIFY_ISSUE=42 CURL_EXIT=7
respond '{"message":"Not Found"}'
run "API error without html_url → exit 1" 1 '-' GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r RALPH_NOTIFY_ISSUE=42
respond '[]' '{"message":"Resource not accessible by personal access token"}'
run "cannot create the issue (token lacks issues:write) → exit 1 with a warning" 1 '-' GITHUB_TOKEN=t GITHUB_REPOSITORY=o/r

echo
echo "  ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
