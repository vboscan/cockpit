#!/usr/bin/env bash
# Dispatch a mechanical task to Antigravity (headless `agy`), per AGENTS.md
# rule 8 — its output goes through the same review gates as any subagent's.
# Runs from the repo root and logs the full transcript to .agy/logs/.
#
# usage: scripts/agy-task.sh [-m "<model label>"] "<task prompt>"
#        model labels: `agy models` (default: $RALPH_AGY_MODEL, .ralph/config.sh —
#        confirm the verbatim label with `agy models` after agy upgrades)
#
# Permission model: auto-mode equivalent — sandboxed shell, repo-scoped edit
# grants, everything else denied headlessly. Canonical description:
# docs/devbox.md §7.
#
# EXIT CODE 75 (EX_TEMPFAIL) means "agy was unavailable, not the task failed" —
# a dispatch timeout or a quota/auth refusal. Delegation is a wall-clock
# optimisation, never a dependency, so ralph/PROMPT.md treats 75 as a signal to
# do the task inline instead. Any other nonzero code is agy's own status: the
# caller must still verify claimed changes on disk before trusting a zero.
set -euo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph-config.sh"

EXIT_UNAVAILABLE=75
TIMEOUT="${AGY_TASK_TIMEOUT:-300}" # a mechanical sub-task that outruns this is
                                   # mis-scoped or hung; either way, stop waiting

model="${RALPH_AGY_MODEL:-Gemini 3.8 Flash (High)}"
while getopts 'm:' opt; do
  case "$opt" in
    m) model="$OPTARG" ;;
    *) echo "usage: $(basename "$0") [-m model] \"<task prompt>\"" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

if [ $# -lt 1 ]; then
  echo "usage: $(basename "$0") [-m model] \"<task prompt>\"" >&2
  exit 2
fi

# Headless dispatch is devbox-only (no public inbound). The image creates this
# marker; refuse to run anywhere else. The path is per-project ($RALPH_DEVBOX_MARKER)
# so two kits sharing one box cannot authorise each other's dispatches.
if [ ! -f "$RALPH_DEVBOX_MARKER" ]; then
  echo "error: refusing to run — $RALPH_DEVBOX_MARKER missing" \
       "(headless dispatch is devbox-only)" >&2
  exit 1
fi

if ! command -v agy >/dev/null 2>&1; then
  echo "error: agy CLI not found — is this running on the devbox?" >&2
  exit 127
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Without repo-scoped edit grants, print mode silently denies file writes
# while the model may still claim success — refuse to dispatch blind. The
# grants must be in the *allow* list specifically (a deny/ask entry with the
# same text must not pass), so parse the JSON rather than grep it.
grants_file="${HOME}/.gemini/config/projects/default-cli-project.json"
if ! python3 - "${grants_file}" "${repo_root}" <<'PYEOF'
import json, sys
try:
    allow = json.load(open(sys.argv[1]))["permissionGrants"]["permissionGrants"]["allow"]
except (OSError, KeyError, ValueError):
    sys.exit(1)
need = {f"write_file({sys.argv[2]}/)", f"edit_file({sys.argv[2]}/)"}
sys.exit(0 if need <= set(allow) else 1)
PYEOF
then
  echo "error: agy allow grants \"write_file(${repo_root}/)\" and" \
       "\"edit_file(${repo_root}/)\" not both present in ${grants_file}" \
       "(permissionGrants.permissionGrants.allow) — see docs/devbox.md §7" >&2
  exit 1
fi

log_dir="${repo_root}/.agy/logs"
mkdir -p "${log_dir}"
log_file="${log_dir}/$(date +%Y%m%d-%H%M%S)-$$.log"

# PLAN.md §11: agents handed tasks read AGENTS.md — put that in the prompt,
# since agy gets no context from the Claude harness.
prompt="First read AGENTS.md at the repository root and obey its hard rules. Task: $*"
printf 'MODEL: %s\nPROMPT: %s\n---\n' "${model}" "${prompt}" > "${log_file}"

start_ts=$(date +%s)
set +e
timeout "${TIMEOUT}" env -C "${repo_root}" agy --sandbox -p "${prompt}" \
  --model "${model}" 2>&1 | tee -a "${log_file}"
status=${PIPESTATUS[0]}
set -e
printf -- '---\nEXIT: %s DURATION: %ss\n' "${status}" "$(( $(date +%s) - start_ts ))" >> "${log_file}"

echo "log: ${log_file}" >&2

# A hung dispatch is indistinguishable from a slow one from the outside, and
# waiting on it burns the caller's own usage window. `timeout` reports 124.
if [ "${status}" -eq 124 ]; then
  echo "agy unavailable: dispatch exceeded ${TIMEOUT}s — do this task inline" >&2
  exit "${EXIT_UNAVAILABLE}"
fi

# Quota and auth refusals are agy being unavailable, not the task being
# impossible. Match on the transcript because agy prints them and exits 1,
# which is otherwise indistinguishable from a task-level failure.
if grep -qiE 'quota exceeded|rate limit|resource exhausted|too many requests|not authenticated|authentication (failed|required)' "${log_file}"; then
  echo "agy unavailable: quota or auth refusal — do this task inline" >&2
  exit "${EXIT_UNAVAILABLE}"
fi

# agy print mode returns nonzero on some successful runs — the exit status is
# passed through for information, but the caller must verify claimed changes
# on disk (git status/diff) and record the outcome in
# docs/delegation-ledger.md after the review gates.
exit "${status}"
