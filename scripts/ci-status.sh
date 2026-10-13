#!/usr/bin/env bash
# Read-only: the check runs for a commit, with failure annotations.
#
# usage: scripts/ci-status.sh [<ref>]     (default HEAD)
#
# Sibling of open-pr.sh: the token comes from `git credential fill` and never
# reaches argv or output. Exists so an iteration (and a human) can see WHY CI is
# red instead of learning it from merge-pr.sh refusing. GET only.
set -euo pipefail
ref="${1:-HEAD}"
sha="$(git rev-parse "${ref}")"
slug=$(git remote get-url origin | sed -E 's#^(https://[^/]+/|git@[^:]+:)##; s#\.git$##')
token=$(printf 'protocol=https\nhost=github.com\n' | git credential fill 2>/dev/null | sed -n 's/^password=//p' || true)
[ -n "${token}" ] || { echo "error: no GitHub credential available via git credential fill" >&2; exit 1; }
api() { curl -sS "https://api.github.com/repos/${slug}/$1" -H "Accept: application/vnd.github+json" -K - <<CURL
header = "Authorization: Bearer ${token}"
CURL
}
api "commits/${sha}/check-runs?per_page=50" | python3 -c '
import json, sys
d = json.load(sys.stdin)
runs = d.get("check_runs", [])
if not runs: print("no check runs visible for", sys.argv[1], "(a fine-grained PAT without the checks permission sees none; workflow runs below are authoritative)"); sys.exit(0)
for r in runs:
    print("%-12s %-40s id=%s" % (r["conclusion"] or r["status"], r["name"], r["id"]))
' "${sha:0:12}"
for id in $(api "commits/${sha}/check-runs?per_page=50" | python3 -c 'import json,sys; [print(r["id"]) for r in json.load(sys.stdin).get("check_runs",[]) if r.get("conclusion") not in (None,"success","skipped")]'); do
  echo "--- annotations for check run ${id} ---"
  api "check-runs/${id}/annotations" | python3 -c '
import json, sys
for a in json.load(sys.stdin):
    print("  [%s] %s:%s — %s" % (a.get("annotation_level"), a.get("path"), a.get("start_line"), (a.get("message") or "")[:400]))
'
done

# Workflow runs for the commit (a workflow that fails to parse produces a run
# with no check runs at all, which is why check runs alone can mislead).
echo "--- workflow runs for ${sha:0:12} ---"
runs_json="$(api "actions/runs?head_sha=${sha}&per_page=20")"
printf '%s' "${runs_json}" | python3 -c '
import json, sys
for r in json.load(sys.stdin).get("workflow_runs", []):
    print("%-12s %-24s run=%s  %s" % (r.get("conclusion") or r.get("status"), r.get("name"), r["id"], r.get("html_url")))
'
for rid in $(printf '%s' "${runs_json}" | python3 -c 'import json,sys; [print(r["id"]) for r in json.load(sys.stdin).get("workflow_runs",[]) if r.get("conclusion") not in (None,"success","skipped")]'); do
  echo "--- jobs for run ${rid} ---"
  jobs_json="$(api "actions/runs/${rid}/jobs?per_page=50")"
  printf '%s' "${jobs_json}" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if not d.get("jobs"): print("  (no jobs — the workflow file itself was rejected; see the run page)")
for j in d.get("jobs", []):
    print("  %-12s job=%s %s" % (j.get("conclusion") or j.get("status"), j["id"], j["name"]))
    for s in j.get("steps", []):
        if s.get("conclusion") not in ("success","skipped",None): print("      step FAILED: %s" % s["name"])
'
  for jid in $(printf '%s' "${jobs_json}" | python3 -c 'import json,sys; [print(j["id"]) for j in json.load(sys.stdin).get("jobs",[]) if j.get("conclusion") not in (None,"success","skipped")]'); do
    echo "--- last 60 log lines of job ${jid} ---"
    curl -sSL "https://api.github.com/repos/${slug}/actions/jobs/${jid}/logs" -H "Accept: application/vnd.github+json" -K - <<CURL | grep -v '^$' | tail -60 | cut -c1-200
header = "Authorization: Bearer ${token}"
CURL
  done
done
