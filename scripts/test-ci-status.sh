#!/usr/bin/env bash
# Behavioural tests for ci-status.sh: read-only, credential never in argv, and
# the "no check runs but a failed workflow run with empty jobs" case is named.
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0; root="$(mktemp -d)"; trap 'rm -rf "${root}"' EXIT
mkdir -p "${root}/bin"; : > "${root}/argv"
cat > "${root}/bin/curl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${root}/argv"
case "\$*" in
  *check-runs*) echo '{"check_runs":[]}' ;;
  *actions/runs/1/jobs*) echo '{"jobs":[{"id":9,"name":"loop-tooling","conclusion":"failure","steps":[]}]}' ;;
  *actions/runs?*) echo '{"workflow_runs":[{"id":1,"name":"ci","conclusion":"failure","status":"completed","html_url":"https://x/runs/1"}]}' ;;
  *actions/jobs/9/logs*) echo 'BlobNotFound' ;;
  *) echo '{}' ;;
esac
STUB
chmod +x "${root}/bin/curl"
d="${root}/repo"; git init -q "$d"; ( cd "$d" && git config user.email t@x && git config user.name t \
  && git config credential.helper '!f() { echo "username=fixture"; echo "password=faketoken"; }; f' \
  && git remote add origin https://github.com/o/r.git && git commit -q --allow-empty -m init )
out="$(cd "$d" && env HOME="${root}" PATH="${root}/bin:${PATH}" bash "${KIT_SCRIPTS}/ci-status.sh" 2>&1)"; st=$?
ok(){ pass=$((pass+1)); echo "  ok  — $1"; }; bad(){ fail=$((fail+1)); echo "  FAIL — $1"; echo "         $2"; }
echo "ci-status.sh"
[[ $st -eq 0 ]] && ok "exits 0 on a readable ref" || bad "exit" "$st: $out"
[[ "$out" == *"no check runs visible"* && "$out" == *"failure      ci"* && "$out" == *"loop-tooling"* ]] && ok "reports no check runs, the failed run and its job" || bad "report" "$out"
! grep -q faketoken "${root}/argv" && ok "token never appears in curl argv" || bad "token in argv" "-"
! grep -qE ' -X (POST|PUT|PATCH|DELETE)' "${root}/argv" && ok "read-only: no write verbs" || bad "write verb used" "$(cat "${root}/argv")"
echo "  ${pass} passed, ${fail} failed"; [[ $fail -eq 0 ]]
