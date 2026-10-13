#!/usr/bin/env bash
# Behavioural tests for comment-pr.sh.
#
# Pinned properties: argument validation happens before any API call; the
# body reaches the API JSON-encoded verbatim (a quote or newline must not
# malform it); the token never appears in argv; a non-comment API answer is an
# error, never a silent success. No network: curl is stubbed and the credential
# helper is faked, as in test-open-pr.sh.
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
root="$(mktemp -d)"; mkdir -p "${root}/fakehome" "${root}/bin"; trap 'rm -rf "${root}"' EXIT

printf '%s\n' '{"html_url":"https://github.com/o/r/pull/7#issuecomment-1"}' > "${root}/curl-post"
cat > "${root}/bin/curl" <<STUB
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  [ "\$prev" = "-d" ] && printf '%s' "\$a" > "${root}/last-payload"
  prev="\$a"
done
printf '%s\n' "\$*" >> "${root}/argv"
echo post >> "${root}/calls"
cat "${root}/curl-post"
STUB
chmod +x "${root}/bin/curl"

dir="${root}/r"; mkdir -p "${dir}"; git init -q --bare "${dir}/remote.git"; git init -q "${dir}/repo"
( cd "${dir}/repo" && git config user.email t@example.test && git config user.name tester \
  && git config credential.helper '!f() { echo "username=fixture"; echo "password=faketoken"; }; f' \
  && git remote add origin "${dir}/remote.git" && git commit -q --allow-empty -m init )
repo="${dir}/repo"

run() { # <desc> <want-exit> <want-substring|-> [args...]
  local desc="$1" want_exit="$2" want_text="$3"; shift 3
  local out status
  out="$(cd "${repo}" && env HOME="${root}/fakehome" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
        PATH="${root}/bin:${PATH}" bash "${KIT_SCRIPTS}/comment-pr.sh" "$@" 2>&1)"; status=$?
  if [[ "${status}" -eq "${want_exit}" ]] && { [[ "${want_text}" == '-' ]] || [[ "${out}" == *"${want_text}"* ]]; }; then
    pass=$((pass+1)); echo "  ok  — ${desc}"
  else
    fail=$((fail+1)); echo "  FAIL — ${desc}"; echo "         want exit ${want_exit} containing '${want_text}'; got ${status}: ${out}"
  fi
}

: > "${root}/calls"
run "no PR number → usage, no call" 2 "usage" --body-file /dev/null
run "non-numeric PR → usage" 2 "usage" abc --body-file /dev/null
run "missing body file → error before any call" 2 "does not exist" 7 --body-file "${root}/nope.md"
[ ! -s "${root}/calls" ] && { pass=$((pass+1)); echo "  ok  — validation failures made no API call"; } \
  || { fail=$((fail+1)); echo "  FAIL — an API call was made despite invalid arguments"; }

printf 'line "one"\nline two\\backslash\n' > "${root}/body.md"
run "valid comment → prints the comment URL" 0 "commented: https://github.com/o/r/pull/7#issuecomment-1" 7 --body-file "${root}/body.md"
if python3 -c '
import json,sys; d=json.load(open(sys.argv[1])); open(sys.argv[2]).read()==d["body"] or sys.exit(1)' "${root}/last-payload" "${root}/body.md"; then
  pass=$((pass+1)); echo "  ok  — body reaches the API JSON-encoded verbatim (quotes, newline, backslash)"
else fail=$((fail+1)); echo "  FAIL — payload body differs from the file"; fi
if ! grep -q faketoken "${root}/argv"; then pass=$((pass+1)); echo "  ok  — token never appears in curl argv"
else fail=$((fail+1)); echo "  FAIL — token leaked into argv"; fi

printf '%s\n' '{"message":"Not Found"}' > "${root}/curl-post"
run "API answer without html_url → error" 1 "comment not created" 7 --body-file "${root}/body.md"

echo "test-comment-pr: ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
