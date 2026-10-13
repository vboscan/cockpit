#!/usr/bin/env bash
# Sum the implementer's OWN transcript for this iteration and append a ledger row.
#
# usage: scripts/usage-session.sh <stage> <spec> <slice> [--since <epoch-seconds>]
#                                  [--root <dir>] [--session <id>]
#   stage is normally `implement`, or `verify` for the /verify portion;
#   `operator` for a standing-operator session (scripts/ralph-operator.sh).
#
# Claude Code writes ~/.claude/projects/<cwd, non-alphanumerics → ->/<session>.jsonl
# with a `usage` block on every assistant turn. This sums the transcripts for this
# repository (or for --root, a session's cwd elsewhere: the operator's kit
# checkout) modified since --since (default: the current branch's point off the
# default branch), so an iteration records what it cost, not what the whole
# project has cost. --session sums that one transcript only. Never fails the caller.
set -uo pipefail
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/usage-lib.sh"
stage="${1-}"; spec="${2-}"; slice="${3-}"; since=""; root=""; session=""
use() { echo "usage: $(basename "$0") <stage> <spec> <slice> [--since <epoch>] [--root <dir>] [--session <id>]" >&2; exit 2; }
[[ -n "${stage}" && -n "${spec}" ]] || use
shift $(($# < 3 ? $# : 3))
while (($#)); do
  case "$1" in --since) since="${2-}" ;; --root) root="${2-}" ;; --session) session="${2-}" ;; *) use ;; esac
  shift 2 || use
done
[[ -n "${root}" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
[[ -z "${since}" && -n "${session}" ]] && since=0 # one session: all of it
if [[ -z "${since}" ]]; then
  base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
  mb="$(git merge-base "${base}" HEAD 2>/dev/null)"
  since="$(git show -s --format=%ct "${mb:-HEAD}" 2>/dev/null || date +%s)"
fi
files=()
while IFS= read -r d; do
  [[ -d "${d}" ]] || continue
  while IFS= read -r f; do files+=("${f}"); done < <(find "${d}" -maxdepth 1 -name "${session:-*}.jsonl" -newermt "@${since}" 2>/dev/null)
done < <(transcript_dirs "${root}")
if (( ${#files[@]} == 0 )); then echo "warn: usage-session: no transcript ${session:+${session} }since ${since} under $(transcript_dirs "${root}" | head -1)" >&2; exit 0; fi
row="$(usage_py - "${stage}" "${spec}" "${slice}" "${since}" "${files[@]}" <<'PY'
import json, sys, os, time
stage, spec, slice_, since = sys.argv[1:5]; files = sys.argv[5:]
i=o=cr=cw=turns=0; models=set(); sessions=[]
for f in files:
    sessions.append(os.path.basename(f).replace(".jsonl",""))
    for line in open(f, errors="ignore"):
        try: d=json.loads(line)
        except ValueError: continue
        if d.get("type")!="assistant": continue
        m=d.get("message") or {}; u=m.get("usage") or {}
        if not u: continue
        turns+=1; models.add(m.get("model","?"))
        i+=u.get("input_tokens",0); o+=u.get("output_tokens",0)
        cr+=u.get("cache_read_input_tokens",0); cw+=u.get("cache_creation_input_tokens",0)
w=float(os.environ["RALPH_W_INPUT"]); wr=float(os.environ["RALPH_W_CACHE_READ"]); ww=float(os.environ["RALPH_W_CACHE_WRITE"]); wo=float(os.environ["RALPH_W_OUTPUT"])
row={"ts":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"spec":spec,"slice":slice_,"stage":stage,
     "model":",".join(sorted(models)) or "unknown","input":i,"output":o,"cache_read":cr,"cache_write":cw,
     "cost_usd":None,"duration_ms":None,"num_turns":turns,"session_id":",".join(sessions),
     "fixed_context_per_turn": round(cr/turns) if turns else 0,
     "weighted":round(i*w+cr*wr+cw*ww+o*wo)}
print(json.dumps(row))
PY
)"
usage_append "${row}"
summary="$(printf '%s' "${row}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["num_turns"], "turns, weighted", d["weighted"])')"
echo "usage-session: recorded ${stage} ${spec} ${slice} (${summary})"
