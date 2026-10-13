#!/usr/bin/env bash
# Open a PR on the GitHub repo via the REST API (no `gh` on the box).
#
# usage: scripts/open-pr.sh --title <title> [--body-file <path>]
#                           [--base <branch>] [--head <branch>]
#
# The twin of merge-pr.sh, and it exists for the same reason: the auto-mode
# permission classifier denies the inline `curl -X POST .../pulls` that
# ralph/ITERATION-ZERO.md used to prescribe, because extracting a PAT from the
# credential store and posting it to a network endpoint is indistinguishable
# from exfiltration. A dedicated script at a fixed path can be allowlisted
# (`Bash(scripts/open-pr.sh *)`) and then passes deterministically, while the
# agent still cannot invent arbitrary API calls. merge-pr.sh got this treatment
# on 2026-07-20; the open half went without it until 2026-09-10, which left
# ralph/PROMPT.md step 6 — the step whose whole point is that the PR number
# must exist before PROGRESS.md records it — blocked on every iteration.
#
# The token comes from `git credential fill` and never appears in argv or
# output.
#
# NOT gated on gate-marker.sh, deliberately. merge-pr.sh asserts the gates
# because it is the last action before main. Step 6 opens the PR BEFORE the
# `confirm` marker is recorded — that ordering is what stops a second write to
# PROGRESS.md moving the tree past the marker — so asserting completeness here
# would deadlock the documented tail order. Do not "fix" this.
set -euo pipefail

title=""
body_file=""
base=""
head=""

while [ $# -gt 0 ]; do
  case "$1" in
    --title)     title="${2-}";     shift 2 || true ;;
    --body-file) body_file="${2-}"; shift 2 || true ;;
    --base)      base="${2-}";      shift 2 || true ;;
    --head)      head="${2-}";      shift 2 || true ;;
    *) echo "error: unknown argument '$1'" >&2
       echo "usage: $(basename "$0") --title <title> [--body-file <path>] [--base <branch>] [--head <branch>]" >&2
       exit 2 ;;
  esac
done

if [ -z "${title}" ]; then
  echo "usage: $(basename "$0") --title <title> [--body-file <path>] [--base <branch>] [--head <branch>]" >&2
  exit 2
fi
if [ -n "${body_file}" ] && [ ! -f "${body_file}" ]; then
  echo "error: --body-file '${body_file}' does not exist" >&2
  exit 2
fi

# Derive owner/repo from origin rather than hardcoding — same as merge-pr.sh,
# so the two halves of the pipeline can never disagree about which repo they
# are acting on.
slug=$(git remote get-url origin | sed -E 's#^(https://[^/]+/|git@[^:]+:)##; s#\.git$##')
owner="${slug%%/*}"

if [ -z "${head}" ]; then
  head="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
fi
if [ -z "${head}" ] || [ "${head}" = "HEAD" ]; then
  echo "error: cannot determine the head branch — detached HEAD? pass --head" >&2
  exit 1
fi

if [ -z "${base}" ]; then
  base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo 'origin/main')"
  base="${base#origin/}"
fi

if [ "${head}" = "${base}" ]; then
  echo "error: head and base are both '${head}' — nothing to open a PR for" >&2
  exit 1
fi

# The branch must be on the remote, at the tip this checkout is on. A PR opened
# for an unpushed or half-pushed branch is a PR whose diff is not the work the
# session just gated — it opens successfully and describes the wrong tree, so
# nothing downstream catches it. ls-remote rather than the remote-tracking ref
# because a stale ref would answer this question with yesterday's fact.
remote_sha="$(git ls-remote origin "refs/heads/${head}" 2>/dev/null | awk '{print $1}' | head -1)"
local_sha="$(git rev-parse HEAD)"
if [ -z "${remote_sha}" ]; then
  echo "error: '${head}' is not on origin — push it before opening the PR:" >&2
  echo "       git push -u origin ${head}" >&2
  exit 1
fi
if [ "${remote_sha}" != "${local_sha}" ]; then
  echo "error: origin/${head} is at ${remote_sha:0:12}, this checkout is at ${local_sha:0:12}." >&2
  echo "       The PR would describe a different tree than the one you gated. Push, then retry." >&2
  exit 1
fi

# `|| true` because a box with no credential helper makes `git credential fill`
# exit 128 ("could not read Username", with prompts disabled), and under
# `set -e` + `pipefail` that kills the script here — so the clear message below
# never prints and the caller sees git's raw error instead. Rescue the pipeline
# and let the emptiness check speak.
token=$(printf 'protocol=https\nhost=github.com\n' | git credential fill 2>/dev/null \
        | sed -n 's/^password=//p' || true)
if [ -z "${token}" ]; then
  echo "error: no GitHub credential available via git credential fill" >&2
  exit 1
fi

# Built by python3, never by string interpolation: a PR body is markdown, and a
# title or body carrying a quote, a newline or a backslash would otherwise
# produce malformed JSON or — worse — a payload that parses into something
# other than what was written.
payload=$(python3 -c '
import json, sys
title, head, base, body_file = sys.argv[1:5]
body = ""
if body_file:
    with open(body_file, encoding="utf-8") as fh:
        body = fh.read()
json.dump({"title": title, "head": head, "base": base, "body": body}, sys.stdout)
' "${title}" "${head}" "${base}" "${body_file}")

# -K - keeps the Authorization header out of argv (invisible to `ps`).
response=$(curl -sS -X POST \
  "https://api.github.com/repos/${slug}/pulls" \
  -H "Accept: application/vnd.github+json" \
  -d "${payload}" \
  -K - <<EOF
header = "Authorization: Bearer ${token}"
EOF
)

# A PR that already exists is the RESUME case, not an error. An iteration that
# died between opening the PR and committing the PROGRESS.md entry gets picked
# up again; the second call has to return the same number it returned the first
# time. GitHub answers the duplicate POST with a 422 that names the collision
# but carries no number, so the number has to be looked up separately.
if printf '%s' "${response}" | grep -qi 'pull request already exists'; then
  existing=$(curl -sS -G \
    "https://api.github.com/repos/${slug}/pulls" \
    -H "Accept: application/vnd.github+json" \
    --data-urlencode "head=${owner}:${head}" \
    --data-urlencode "state=open" \
    -K - <<EOF
header = "Authorization: Bearer ${token}"
EOF
)
  python3 -c '
import json, sys
head, raw = sys.argv[1], sys.argv[2]
try:
    d = json.load(sys.stdin)
except ValueError:
    print("error: unparseable API response looking up the open PR for %s: %s" % (head, raw[:200]), file=sys.stderr)
    sys.exit(1)
# The ambiguous state resolves to failure, never to a guessed number. The whole
# reason this script exists is that PROGRESS.md must record a real PR number:
# printing one we are not sure of is the exact defect the "never a predicted
# number" rule in ralph/PROMPT.md step 6 was written to stop.
if not isinstance(d, list) or not d:
    print("error: the API says a PR already exists for %s, but no open PR was found for it." % head, file=sys.stderr)
    print("       It may have been closed, or opened against a different base. Resolve by hand.", file=sys.stderr)
    sys.exit(1)
pr = d[0]
print("PR #%s already open for %s: %s" % (pr["number"], head, pr["html_url"]))
' "${head}" "${existing}" <<<"${existing}"
  exit $?
fi

python3 -c '
import json, sys
head, raw = sys.argv[1], sys.argv[2]
try:
    d = json.load(sys.stdin)
except ValueError:
    print("error: unparseable API response opening a PR for %s: %s" % (head, raw[:200]), file=sys.stderr)
    sys.exit(1)
if isinstance(d, dict) and d.get("number"):
    print("opened PR #%s: %s" % (d["number"], d["html_url"]))
    sys.exit(0)
msg = d.get("message", d) if isinstance(d, dict) else d
errors = d.get("errors") if isinstance(d, dict) else None
if errors:
    detail = "; ".join(e.get("message", str(e)) for e in errors if isinstance(e, dict)) or str(errors)
    print("error: no PR opened for %s: %s (%s)" % (head, msg, detail), file=sys.stderr)
    sys.exit(1)
print("error: no PR opened for %s: %s" % (head, msg), file=sys.stderr)
sys.exit(1)
' "${head}" "${response}" <<<"${response}"
