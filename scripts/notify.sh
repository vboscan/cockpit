#!/usr/bin/env bash
# Non-blocking owner notification, delivered as a comment on a GitHub issue in
# the project's own repository (ralph/PROMPT.md preconditions and step 8; the
# driver, heartbeat and sentinel). Replaced ntfy on 2026-09-30: the owner already
# watches GitHub to merge, so stops, gates and summaries land where the PRs are,
# with no extra account and no topic to keep secret.
#
# usage: scripts/notify.sh [-t "<title>"] "<message>"
#
# Target issue: RALPH_NOTIFY_ISSUE (a number, .ralph/config.sh) or, when unset,
# the open issue titled RALPH_NOTIFY_ISSUE_TITLE, created if none exists.
# Credential: `git credential fill` (never on argv, never printed), else
# GITHUB_TOKEN — a CI runner has no credential store. Repository: origin's URL,
# else GITHUB_REPOSITORY. Any failure exits nonzero with a warning; callers log
# it and continue — a notification must never block an iteration.
# The auto-mode classifier denies an inline credentialed curl, so this script
# lives at a fixed path and is allowlisted: Bash(scripts/notify.sh *).
# (no -e: every failure path is explicit; the exit-1 contract is the point)
set -uo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph-config.sh"

title="$RALPH_NOTIFY_TITLE"
while getopts 't:' opt; do
  case "$opt" in
    t) title="$OPTARG" ;;
    *) echo "usage: $(basename "$0") [-t title] \"<message>\"" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
if [ $# -lt 1 ]; then
  echo "usage: $(basename "$0") [-t title] \"<message>\"" >&2
  exit 2
fi
message="$*"

# Under an operator, every notification is also a line in its journal
# (scripts/operator-lib.sh), journalled before the network can fail.
# RALPH_NOTIFY_KIND labels the entry for its reader (info: nothing to act on).
# No notification wakes the operator; only a stop does (ralph-operator.sh wait).
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/operator-lib.sh"
op_event "${RALPH_NOTIFY_KIND:-notified}" "${title}: ${message}"

# The project's origin, not the cwd's: the operator runs this from its kit
# checkout (ralph-operator.sh note), where origin is the kit repository.
slug="$(git -C "$RALPH_REPO_ROOT" remote get-url origin 2>/dev/null | sed -E 's#^(https://[^/]+/|git@[^:]+:)##; s#\.git$##')"
: "${slug:=${GITHUB_REPOSITORY:-}}"
if [ -z "${slug}" ]; then
  echo "warn: notify: no origin remote and no GITHUB_REPOSITORY — notification skipped" >&2
  exit 1
fi
token="$(printf 'protocol=https\nhost=github.com\n' | GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null \
         | sed -n 's/^password=//p' || true)"
: "${token:=${GITHUB_TOKEN:-}}"
if [ -z "${token}" ]; then
  echo "warn: notify: no GitHub credential (git credential fill, GITHUB_TOKEN) — notification skipped" >&2
  exit 1
fi

# api <method> <path> [json-body] — the token travels in a -K config on stdin,
# never on the command line (same shape as open-pr.sh / comment-pr.sh).
api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "${data}" ]; then
    curl -sS -m 15 -X "${method}" "https://api.github.com/repos/${slug}/${path}" \
      -H "Accept: application/vnd.github+json" -d "${data}" -K - <<CURL
header = "Authorization: Bearer ${token}"
CURL
  else
    curl -sS -m 15 -X "${method}" "https://api.github.com/repos/${slug}/${path}" \
      -H "Accept: application/vnd.github+json" -K - <<CURL
header = "Authorization: Bearer ${token}"
CURL
  fi
}

issue="${RALPH_NOTIFY_ISSUE:-}"
if [ -z "${issue}" ]; then
  # Find the open issue by exact title; pull requests are issues too and are skipped.
  list="$(api GET "issues?state=open&per_page=100")" || { echo "warn: notify: could not list issues" >&2; exit 1; }
  issue="$(printf '%s' "${list}" | python3 -c '
import json, sys
want = sys.argv[1]
try: items = json.load(sys.stdin)
except ValueError: sys.exit(0)
if not isinstance(items, list): sys.exit(0)
for it in items:
    if it.get("title") == want and "pull_request" not in it:
        print(it["number"]); break
' "${RALPH_NOTIFY_ISSUE_TITLE}")"
fi
if [ -z "${issue}" ]; then
  body="$(python3 -c '
import json, sys
json.dump({"title": sys.argv[1], "body": "Comments here are posted by the loop'"'"'s scripts (ralph/PROMPT.md step 8, the driver, heartbeat and sentinel): iteration summaries, owner gates, stops. Keep this issue open; pin it with RALPH_NOTIFY_ISSUE in .ralph/config.sh to skip the lookup."}, sys.stdout)
' "${RALPH_NOTIFY_ISSUE_TITLE}")"
  created="$(api POST "issues" "${body}")" || { echo "warn: notify: could not create the notifications issue" >&2; exit 1; }
  issue="$(printf '%s' "${created}" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except ValueError: sys.exit(0)
if isinstance(d, dict) and "number" in d: print(d["number"])
')"
  if [ -z "${issue}" ]; then
    echo "warn: notify: notifications issue not found or created: $(printf '%s' "${created}" | cut -c1-200)" >&2
    exit 1
  fi
fi

payload="$(python3 -c '
import json, sys
json.dump({"body": "**%s**\n\n%s" % (sys.argv[1], sys.argv[2])}, sys.stdout)
' "${title}" "${message}")"
response="$(api POST "issues/${issue}/comments" "${payload}")" || { echo "warn: notify: send failed" >&2; exit 1; }
printf '%s' "${response}" | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except ValueError: print("warn: notify: unparseable API response", file=sys.stderr); sys.exit(1)
if not isinstance(d, dict) or "html_url" not in d:
    print("warn: notify: comment not created: %s" % (d.get("message", d) if isinstance(d, dict) else d), file=sys.stderr); sys.exit(1)
print("notified: %s" % d["html_url"])
'
