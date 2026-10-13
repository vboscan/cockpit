#!/usr/bin/env bash
# The one way headless sessions are launched (README "Where the budget goes").
#
# usage: scripts/claude-run.sh <stage> <spec> <slice> -- <claude -p arguments…>
#   stage: slice | red | plan-review | security-review | code-review |
#          spec-review | adversary | confirm | explain | judge | other
#   exit:  the session's, or 2 usage / refused flag, 3 wrote outside its scope,
#          4 over its token cap (scripts/token-sentinel.sh)
#
# Adds --output-format json, prints the model's text to stdout exactly as a
# plain `claude -p` would, and appends one ledger row: ts, spec, slice, stage,
# model, input, output, cache_read, cache_write, cost_usd, duration_ms,
# num_turns, session_id, weighted. The ledger never fails the call: an
# unparseable envelope is passed through verbatim with a warning.
#
# Write access is decided HERE, by stage, never by the caller (README "What a
# headless stage may write"):
#   red            file edits in the working directory (--permission-mode
#                  acceptEdits): tests, compile-only stubs, the plan.
#   adversary      the same grant, and it may change TEST FILES ONLY: an
#                  adversary that can edit the implementation can fix what it
#                  was sent to expose.
#   everything else  no flag at all, so the client refuses every write — a
#                  reviewer that could edit could edit what it is grading.
# No stage gets the toolchain or git: scripts/ralph-iterate.sh observes red and
# commits checkpoint(red); the implementer runs and commits the adversary's tests.
# A caller that passes its own permission flag is refused (exit 2). acceptEdits
# does not know a test from a spec, so a writing stage is also launched with a
# deny rule for every path the loop is graded against: the kit's own files
# (.ralph/kit-manifest), specs/, .claude/, .github/, .ralph/config.sh, the
# governance docs, plus $RALPH_RED_PROTECTED. The client refuses writes there.
# The same paths are hashed before and after the run, because a deny rule is a
# fact about one client version; for the adversary the whole tree is (git's
# view of it: tracked and unignored files), because "test files only" cannot be
# written as a deny rule. Any difference outside the stage's scope is exit 3
# with the paths on stderr. Nothing is reverted — the script cannot tell the
# session's write from one the caller made meanwhile.
#
# Every stage runs under scripts/token-sentinel.sh: the session is launched with
# a --session-id (the caller's, else a fresh one) so its transcript can be read
# while it runs, and past the stage's cap (RALPH_TOKEN_CAP, or RALPH_TOKEN_CAP_
# <STAGE>) it is killed, the breach recorded as its ledger row with "over_cap",
# the owner notified, exit 4. A stage that finished over the cap — one last
# turn can be most of it — is exit 4 the same way, its text printed and its row
# recorded, so the caller stops the loop rather than build on a leak.
set -uo pipefail
# shellcheck source=/dev/null
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/usage-lib.sh
. "$HERE/usage-lib.sh"

stage="${1-}"; spec="${2-}"; slice="${3-}"
[[ "${4-}" == "--" && -n "${stage}" && -n "${spec}" ]] || { echo "usage: $(basename "$0") <stage> <spec> <slice> -- <claude -p args…>" >&2; exit 2; }
shift 4
model="unknown"; prev=""
for a in "$@"; do [[ "${prev}" == "--model" ]] && model="${a}"; prev="${a}"; done

for a in "$@"; do case "${a}" in
  --permission-mode|--permission-mode=*|--dangerously-skip-permissions|--allow-dangerously-skip-permissions|--allowedTools|--allowedTools=*|--allowed-tools|--allowed-tools=*)
    echo "claude-run: ${a%%=*} refused — this script decides write access by stage (red: file edits; adversary: test files; every other stage: none)" >&2; exit 2 ;;
esac; done

# is_test: what the adversary may write. The same line as drift-check.sh's —
# test-usage-ledger.sh compares the two.
is_test() { case "$1" in *_test.go|*.test.ts|*.spec.ts|test_*.py|*/test_*.py|*_test.py|test-*.sh|*/test-*.sh|test_*.sh|*/test_*.sh|*_test.sh|*.bats) return 0;; *) return 1;; esac; }

# scope <hashes|rules|tree>: what a writing stage is held to.
#   hashes  one "<sha256>  <path>" line per file under a protected path
#   rules   one client deny rule per protected path (Edit rules bind every
#           file-editing tool and the shell's rm, mv, sed -i and redirects)
#   tree    one "<sha256>  <path>" line per tracked or unignored file; a
#           submodule counts as its commit plus its status. Fails outside git.
scope() { python3 -c '
import hashlib, os, subprocess, sys
mode, root, extra = sys.argv[1], sys.argv[2], sys.argv[3].split()
dirs  = ["specs", ".claude", ".github"]
files = [".ralph/config.sh", ".ralph/kit-manifest", "AGENTS.md", "CLAUDE.md", "PLAN.md",
         "PROGRESS.md", "PROGRESS-archive.md"]
try: files += [l.strip() for l in open(os.path.join(root, ".ralph/kit-manifest")) if l.strip()]
except OSError: pass
def git(d, *args): return subprocess.run(["git", "-C", d] + list(args), capture_output=True)
def under(rel):
    p = os.path.join(root, rel)
    if os.path.islink(p) or os.path.isfile(p): yield rel
    elif os.path.isdir(p):
        for d, _, names in os.walk(p):
            for n in names: yield os.path.relpath(os.path.join(d, n), root)
def digest(rel):
    p = os.path.join(root, rel)
    try:
        if os.path.islink(p): data = os.readlink(p).encode()
        elif os.path.isdir(p): data = git(p, "rev-parse", "HEAD").stdout + git(p, "status", "--porcelain").stdout
        else: data = open(p, "rb").read()
    except OSError: return "absent"
    return hashlib.sha256(data).hexdigest()
if mode == "rules":
    for r in sorted({root, os.path.realpath(root)}):
        for d in dirs + extra: print("Edit(/%s/%s/**)" % (r, d))
        for f in files + extra: print("Edit(/%s/%s)" % (r, f))
elif mode == "tree":
    ls = git(root, "ls-files", "-co", "--exclude-standard", "-z")
    if ls.returncode: sys.exit(1)
    for rel in sorted(set(ls.stdout.decode(errors="replace").split("\0")) - {""}):
        print(digest(rel) + "  " + rel.rstrip("/"))
else:
    for rel in sorted({f for p in dirs + files + extra for f in under(p)}): print(digest(rel) + "  " + rel)
' "$1" "${RALPH_REPO_ROOT}" "${RALPH_RED_PROTECTED-}"; }
# changed <before> <after>: the paths whose line differs between two listings
changed() { LC_ALL=C comm -3 <(printf '%s\n' "$1" | LC_ALL=C sort) <(printf '%s\n' "$2" | LC_ALL=C sort) | sed 's/^\t//' | cut -d' ' -f3- | LC_ALL=C sort -u; }

writes=0; tests_only=0; before=""; tree_before=""
case "${stage}" in
  red)       writes=1 ;;
  adversary) writes=1; tests_only=1 ;;
esac
if (( writes )); then
  before="$(scope hashes)"
  if (( tests_only )); then
    tree_before="$(scope tree)" || { echo "claude-run: ${stage} needs a git work tree at ${RALPH_REPO_ROOT} — without one, what the session wrote cannot be told" >&2; exit 2; }
  fi
  rules=(); while IFS= read -r r; do rules+=("${r}"); done < <(scope rules)
  set -- "$@" --permission-mode acceptEdits --disallowedTools "${rules[@]}"
fi

# The session id is pinned so the sentinel can find the transcript while the
# session runs; a caller's own --session-id (or --resume <id>, whose transcript
# already exists under that id) is kept.
sid=""; prev=""
for a in "$@"; do
  case "${prev}" in --session-id|--resume|-r) sid="${a}" ;; esac
  case "${a}" in --session-id=*) sid="${a#--session-id=}" ;; --resume=*) sid="${a#--resume=}" ;; esac
  prev="${a}"
done
if [[ -z "${sid}" ]]; then sid="$(python3 -c 'import uuid; print(uuid.uuid4())')"; set -- "$@" --session-id "${sid}"; fi
cap="$("$HERE/token-sentinel.sh" cap "${stage}")"

raw="$("$HERE/token-sentinel.sh" watch "${stage}" "${spec}" "${slice}" "${sid}" -- claude "$@" --output-format json)"; status=$?
row="$(printf '%s' "${raw}" | usage_py -c '
import json, sys, os, time
stage, spec, slice_, model, status, cap = sys.argv[1:7]
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    if d.get("type") != "result": raise ValueError("not a result envelope")
except Exception:
    sys.stdout.write(raw)            # pass through
    print("\n__LEDGER__{}", end="")  # empty row marker
    sys.exit()
u = d.get("usage") or {}
w = float(os.environ["RALPH_W_INPUT"]); wr = float(os.environ["RALPH_W_CACHE_READ"])
ww = float(os.environ["RALPH_W_CACHE_WRITE"]); wo = float(os.environ["RALPH_W_OUTPUT"])
i, o = u.get("input_tokens", 0), u.get("output_tokens", 0)
cr, cw = u.get("cache_read_input_tokens", 0), u.get("cache_creation_input_tokens", 0)
mu = d.get("modelUsage") or {}
if model == "unknown" and len(mu) == 1: model = next(iter(mu))
row = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "spec": spec, "slice": slice_,
       "stage": stage, "model": model, "input": i, "output": o, "cache_read": cr, "cache_write": cw,
       "cost_usd": d.get("total_cost_usd", 0), "duration_ms": d.get("duration_ms", 0),
       "num_turns": d.get("num_turns", 0), "session_id": d.get("session_id", ""),
       "is_error": bool(d.get("is_error")), "exit": int(status),
       "weighted": round(i*w + cr*wr + cw*ww + o*wo)}
row["cap"] = int(cap); row["over_cap"] = bool(int(cap) > 0 and row["weighted"] > int(cap))
if row["over_cap"]: row["exit"] = 4
sys.stdout.write(d.get("result") or "")
print("\n__LEDGER__" + json.dumps(row), end="")
' "${stage}" "${spec}" "${slice}" "${model}" "${status}" "${cap}")"
text="${row%$'\n'__LEDGER__*}"; ledger="${row##*__LEDGER__}"
printf '%s\n' "${text}"
if [[ "${ledger}" == "{}" ]]; then
  # Killed by the sentinel: no envelope, and the breach is already its row.
  (( status == 4 )) || echo "warn: claude-run: no result envelope — not recorded" >&2
else
  usage_append "${ledger}"
  if [[ "${ledger}" == *'"over_cap": true'* ]]; then
    "$HERE/token-sentinel.sh" report "${stage}" "${spec}" "${slice}" \
      "$(printf '%s' "${ledger}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["weighted"])')" "${cap}"
    status=4
  fi
fi
if (( writes )); then
  touched="$(changed "${before}" "$(scope hashes)")"
  if (( tests_only )); then
    while IFS= read -r f; do [[ -z "${f}" ]] || is_test "${f}" || touched+=$'\n'"${f}"; done < <(changed "${tree_before}" "$(scope tree)")
    touched="$(printf '%s\n' "${touched}" | sed '/^$/d' | LC_ALL=C sort -u)"
  fi
  if [[ -n "${touched}" ]]; then
    echo "claude-run: the ${stage} session changed paths it may not write — revert them before anything is committed:" >&2
    printf '%s\n' "${touched}" | sed 's/^/  /' >&2
    exit 3
  fi
fi
exit "${status}"
