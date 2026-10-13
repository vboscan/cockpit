#!/usr/bin/env bash
# Behavioural tests for claude-run.sh, usage-session.sh and usage-report.sh.
# No network: `claude` is stubbed on PATH; transcripts are fixtures.
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0; root="$(mktemp -d)"; trap 'rm -rf "${root}"' EXIT
mkdir -p "${root}/bin" "${root}/cfg"
export RALPH_USAGE_LEDGER="${root}/cfg/usage.jsonl" RALPH_PROJECT_NAME=test
ok()   { pass=$((pass+1)); echo "  ok  — $1"; }
bad()  { fail=$((fail+1)); echo "  FAIL — $1"; echo "         $2"; }

# --- stub claude: emits a real-shaped result envelope, or garbage on demand ---
cat > "${root}/bin/claude" <<'STUB'
#!/usr/bin/env bash
[ "${CLAUDE_STUB_GARBAGE:-}" = 1 ] && { echo "not json at all"; exit 0; }
printf '%s\n' "$*" >> "${CLAUDE_STUB_ARGV}"
# CLAUDE_STUB_LEAK=<n>: a session that writes n turns to its transcript (at the
# --session-id it was given, under the cwd's transcript dir) and never ends.
if [ -n "${CLAUDE_STUB_LEAK:-}" ]; then
  sid=""; prev=""; for a in "$@"; do [ "$prev" = --session-id ] && sid="$a"; prev="$a"; done
  d="${RALPH_TRANSCRIPT_DIR}/$(pwd | sed 's/[^A-Za-z0-9]/-/g')"; mkdir -p "$d"; echo $$ > "${CLAUDE_STUB_ARGV}.pid"
  for i in $(seq 1 "${CLAUDE_STUB_LEAK}"); do echo '{"type":"assistant","message":{"model":"m","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":10000,"output_tokens":300}}}' >> "$d/$sid.jsonl"; done
  sleep 20; exit 0
fi
for f in ${CLAUDE_STUB_WRITE:-}; do mkdir -p "$(dirname "$f")"; echo "written by the session" >> "$f"; done
for f in ${CLAUDE_STUB_DELETE:-}; do rm -f "$f"; done
cat <<'J'
{"type":"result","subtype":"success","is_error":false,"duration_ms":1050,"num_turns":1,"result":"the model said this","session_id":"sess-1","total_cost_usd":0.02,"usage":{"input_tokens":10,"cache_creation_input_tokens":9000,"cache_read_input_tokens":13000,"output_tokens":40},"modelUsage":{"claude-haiku-4-5-20251001":{}}}
J
STUB
chmod +x "${root}/bin/claude"; export CLAUDE_STUB_ARGV="${root}/argv"; : > "${CLAUDE_STUB_ARGV}"
run_cr() { (cd "${root}" && PATH="${root}/bin:${PATH}" bash "${KIT_SCRIPTS}/claude-run.sh" "$@" 2>"${root}/err"); }

echo "claude-run.sh"
out="$(run_cr red 08 s1 -- -p --model claude-fable-5 "/tdd red 08 s1")"; st=$?
[[ $st -eq 0 && "$out" == "the model said this" ]] && ok "prints the model's text, exit 0" || bad "text/exit" "got $st: $out"
grep -q -- '--output-format json' "${CLAUDE_STUB_ARGV}" && ok "adds --output-format json to the call" || bad "no json flag" "$(cat "${CLAUDE_STUB_ARGV}")"
row="$(tail -1 "${RALPH_USAGE_LEDGER}")"
python3 - "$row" <<'PY' && ok "ledger row has stage/spec/model/tokens and weighted = 10 + 1300 + 18000 + 200" || bad "row fields" "$row"
import json,sys; d=json.loads(sys.argv[1])
assert d["stage"]=="red" and d["spec"]=="08" and d["slice"]=="s1" and d["model"]=="claude-fable-5"
assert d["input"]==10 and d["cache_read"]==13000 and d["cache_write"]==9000 and d["output"]==40
assert d["weighted"]==19510, d["weighted"]; assert d["session_id"]=="sess-1"
PY
out="$(CLAUDE_STUB_GARBAGE=1 run_cr code-review 08 s1 -- -p "x")"; st=$?
[[ "$out" == "not json at all" ]] && grep -q "not recorded" "${root}/err" && ok "non-JSON output passes through with a warning, no row" || bad "passthrough" "got: $out / $(cat "${root}/err")"
[[ "$(wc -l < "${RALPH_USAGE_LEDGER}")" -eq 1 ]] && ok "garbage did not add a row" || bad "row count" "$(cat "${RALPH_USAGE_LEDGER}")"
run_cr 2>/dev/null; [[ $? -eq 2 ]] && ok "usage error without stage/spec/--" || bad "usage exit" "-"

# --- write scope: red may edit files, nobody else may, and never the loop's own rules ---
echo "claude-run.sh write scope"
proj="${root}/proj"; mkdir -p "${proj}/specs" "${proj}/scripts" "${proj}/.ralph/logs" "${proj}/.claude/skills/tdd" "${proj}/.github/workflows" "${proj}/ralph" "${proj}/docs/adr"
echo "criteria" > "${proj}/specs/01-thing.md"; echo "rules" > "${proj}/AGENTS.md"; echo "table" > "${proj}/PROGRESS.md"
echo "checker" > "${proj}/scripts/drift-check.sh"; echo "the project's own" > "${proj}/scripts/build.sh"
echo "prompt" > "${proj}/ralph/PROMPT.md"; echo "skill" > "${proj}/.claude/skills/tdd/SKILL.md"; echo "ci" > "${proj}/.github/workflows/ci.yml"
echo ': "${RALPH_STUB_MAX_LINES:=40}"' > "${proj}/.ralph/config.sh"; echo "decision" > "${proj}/docs/adr/0001.md"
printf '%s\n' ralph/PROMPT.md scripts/drift-check.sh .claude/skills/tdd/SKILL.md > "${proj}/.ralph/kit-manifest"
# run_ws <env assignments…> -- <claude-run args…>: a run inside the fixture project
run_ws() { local e=(); while [[ "$1" != "--" ]]; do e+=("$1"); shift; done; shift
  (cd "${proj}" && env "${e[@]}" RALPH_REPO_ROOT="${proj}" RALPH_CONFIG="${proj}/.ralph/config.sh" PATH="${root}/bin:${PATH}" bash "${KIT_SCRIPTS}/claude-run.sh" "$@" 2>"${root}/err"); }
argv_last() { tail -1 "${CLAUDE_STUB_ARGV}"; }

out="$(run_ws CLAUDE_STUB_WRITE="pkg/thing_test.go pkg/thing.go ralph/plan-01-thing-1.md scripts/build.sh" -- red 09 s1 -- -p --model m "/tdd red")"; st=$?
[[ $st -eq 0 && "$out" == "the model said this" ]] && ok "red writing tests, a stub, its plan and a project script: exit 0" || bad "red clean run" "got $st: $out / $(cat "${root}/err")"
[[ "$(argv_last)" == *"--permission-mode acceptEdits"* ]] && ok "red is launched with --permission-mode acceptEdits" || bad "red flag" "$(argv_last)"
[[ -s "${proj}/pkg/thing_test.go" && -s "${proj}/ralph/plan-01-thing-1.md" ]] && ok "red's files are on disk" || bad "red files" "$(ls -R "${proj}/pkg" 2>&1)"
rroot="$(cd "${proj}" && pwd -P)"; a="$(argv_last)"; miss=""
for r in "Edit(/${rroot}/specs/**)" "Edit(/${rroot}/.claude/**)" "Edit(/${rroot}/.github/**)" "Edit(/${rroot}/AGENTS.md)" "Edit(/${rroot}/PROGRESS.md)" "Edit(/${rroot}/.ralph/config.sh)" "Edit(/${rroot}/scripts/drift-check.sh)" "Edit(/${rroot}/ralph/PROMPT.md)"; do [[ "${a}" == *"${r}"* ]] || miss+=" ${r}"; done
[[ "${a}" == *"--disallowedTools Edit("* && -z "${miss}" ]] && ok "red is launched with a deny rule per protected path (specs, kit files, governance docs, config, CI)" || bad "deny rules" "missing:${miss}"
[[ "${a}" != *"scripts/build.sh"* && "${a}" != *"ralph/plan-"* && "${a}" != *"/.ralph/**"* ]] && ok "no deny rule for the project's own files, the plan or the loop's runtime state" || bad "deny rules too wide" "${a}"
[[ "${a}" == *" --output-format json" ]] && ok "the deny list ends before --output-format, so it cannot swallow it" || bad "flag order" "${a: -80}"

for stage in plan-review security-review code-review spec-review confirm explain judge other; do
  run_ws -- "${stage}" 09 s1 -- -p --model m "x" >/dev/null
  [[ "$(argv_last)" != *"--permission-mode"* && "$(argv_last)" != *"--disallowedTools"* ]] || { bad "${stage} got permission flags" "$(argv_last)"; continue; }
  ok "${stage} is launched with no permission flag (the client refuses its writes)"
done

calls="$(wc -l < "${CLAUDE_STUB_ARGV}")"
for flag in "--permission-mode acceptEdits" "--permission-mode=bypassPermissions" "--dangerously-skip-permissions" "--allow-dangerously-skip-permissions" "--allowedTools Edit" "--allowed-tools=Edit"; do
  # shellcheck disable=SC2086
  run_ws -- code-review 09 s1 -- -p --model m ${flag} "x" >/dev/null; st=$?
  [[ $st -eq 2 ]] && grep -q "decides write access" "${root}/err" && ok "caller-supplied ${flag%%[ =]*} is refused, exit 2" || bad "caller flag ${flag}" "got $st: $(cat "${root}/err")"
done
run_ws -- red 09 s1 -- -p --model m --permission-mode bypassPermissions "x" >/dev/null; st=$?
[[ $st -eq 2 ]] && ok "red cannot be widened by the caller either" || bad "red widened" "got $st"
[[ "$(wc -l < "${CLAUDE_STUB_ARGV}")" -eq "${calls}" ]] && ok "a refused call never reaches claude" || bad "refused call ran" "$(tail -3 "${CLAUDE_STUB_ARGV}")"

rows="$(wc -l < "${RALPH_USAGE_LEDGER}")"
out="$(run_ws CLAUDE_STUB_WRITE="specs/01-thing.md pkg/more_test.go" -- red 09 s1 -- -p --model m "/tdd red")"; st=$?
[[ $st -eq 3 ]] && grep -q "specs/01-thing.md" "${root}/err" && ! grep -q "more_test.go" "${root}/err" && ok "red editing a spec: exit 3, the spec named, the test not" || bad "spec edit" "got $st: $(cat "${root}/err")"
[[ "$out" == "the model said this" && "$(wc -l < "${RALPH_USAGE_LEDGER}")" -eq $((rows+1)) ]] && ok "a refused run still prints the text and records its ledger row" || bad "refused run output/ledger" "$out"
echo "criteria" > "${proj}/specs/01-thing.md"

run_ws CLAUDE_STUB_WRITE="specs/02-invented.md scripts/drift-check.sh AGENTS.md PROGRESS.md .ralph/config.sh .github/workflows/ci.yml .claude/settings.json" CLAUDE_STUB_DELETE="ralph/PROMPT.md" -- red 09 s1 -- -p --model m "x" >/dev/null; st=$?
miss=""; for f in specs/02-invented.md scripts/drift-check.sh AGENTS.md PROGRESS.md .ralph/config.sh .github/workflows/ci.yml .claude/settings.json ralph/PROMPT.md; do grep -q -- "${f}" "${root}/err" || miss+=" ${f}"; done
[[ $st -eq 3 && -z "${miss}" ]] && ok "new spec, kit script, AGENTS, PROGRESS, config, CI, settings and a deleted kit file are all named" || bad "protected set" "got $st, missing:${miss} / $(cat "${root}/err")"
rm -f "${proj}/specs/02-invented.md" "${proj}/.claude/settings.json"; echo "prompt" > "${proj}/ralph/PROMPT.md"
echo ': "${RALPH_STUB_MAX_LINES:=40}"' > "${proj}/.ralph/config.sh"

run_ws CLAUDE_STUB_WRITE=".ralph/heartbeat.out .ralph/logs/iter.log" -- red 09 s1 -- -p --model m "x" >/dev/null; st=$?
[[ $st -eq 0 ]] && ok "the loop's runtime state under .ralph/ moving during the run is not a finding" || bad "runtime state" "got $st: $(cat "${root}/err")"
run_ws CLAUDE_STUB_WRITE="docs/adr/0001.md" -- red 09 s1 -- -p --model m "x" >/dev/null; st=$?
[[ $st -eq 0 ]] && ok "an unlisted project path is writable by default" || bad "default scope" "got $st"
run_ws RALPH_RED_PROTECTED="docs/adr vendor" CLAUDE_STUB_WRITE="docs/adr/0002.md" -- red 09 s1 -- -p --model m "x" >/dev/null; st=$?
[[ $st -eq 3 ]] && grep -q "docs/adr/0002.md" "${root}/err" && ok "RALPH_RED_PROTECTED adds project paths (a directory covers what is under it)" || bad "extra protected" "got $st: $(cat "${root}/err")"
a="$(argv_last)"
[[ "${a}" == *"Edit(/${rroot}/docs/adr/**)"* && "${a}" == *"Edit(/${rroot}/docs/adr)"* && "${a}" == *"Edit(/${rroot}/vendor/**)"* ]] && ok "and a deny rule for each, as a file and as a directory (one may not exist yet)" || bad "extra deny rules" "${a}"
run_ws CLAUDE_STUB_WRITE="specs/01-thing.md" -- code-review 09 s1 -- -p --model m "x" >/dev/null; st=$?
[[ $st -eq 0 ]] && ok "the check belongs to stages that can write: a review stage is not hashed" || bad "review stage hashed" "got $st"

# --- adversary: the same grant, and the session may change test files only ---
echo "claude-run.sh adversary scope"
git -C "${proj}" init -q; echo "out/" > "${proj}/.gitignore"
out="$(run_ws CLAUDE_STUB_WRITE="pkg/attack_test.go pkg/thing_test.go web/replay.test.ts tests/test_attack.py out/build.log" -- adversary 09 s1 -- -p --model m "attack")"; st=$?
[[ $st -eq 0 && "$out" == "the model said this" ]] && ok "adversary adding and extending tests (Go, TS, Python) plus an ignored build output: exit 0" || bad "adversary clean run" "got $st: $(cat "${root}/err")"
a="$(argv_last)"
[[ "${a}" == *"--permission-mode acceptEdits"* && "${a}" == *"Edit(/${rroot}/specs/**)"* ]] && ok "adversary is launched with acceptEdits and the same deny rules as red" || bad "adversary flags" "${a}"
run_ws CLAUDE_STUB_WRITE="pkg/thing.go pkg/more_attack_test.go" -- adversary 09 s1 -- -p --model m "x" >/dev/null; st=$?
[[ $st -eq 3 ]] && grep -q "pkg/thing.go" "${root}/err" && ! grep -q "more_attack_test.go" "${root}/err" && ok "adversary editing the implementation: exit 3, the source file named, the test not" || bad "adversary edits source" "got $st: $(cat "${root}/err")"
run_ws CLAUDE_STUB_WRITE="pkg/helper.go" -- adversary 09 s1 -- -p --model m "x" >/dev/null; st=$?
[[ $st -eq 3 ]] && grep -q "pkg/helper.go" "${root}/err" && ok "adversary creating a non-test file: exit 3" || bad "adversary new source" "got $st: $(cat "${root}/err")"
rm -f "${proj}/pkg/helper.go"
run_ws CLAUDE_STUB_DELETE="scripts/build.sh" -- adversary 09 s1 -- -p --model m "x" >/dev/null; st=$?
[[ $st -eq 3 ]] && grep -q "scripts/build.sh" "${root}/err" && ok "adversary deleting a non-test file: exit 3" || bad "adversary delete" "got $st: $(cat "${root}/err")"
echo "the project's own" > "${proj}/scripts/build.sh"
run_ws CLAUDE_STUB_WRITE="specs/01-thing.md" -- adversary 09 s1 -- -p --model m "x" >/dev/null; st=$?
[[ $st -eq 3 && "$(grep -c "specs/01-thing.md" "${root}/err")" -eq 1 ]] && ok "adversary editing a spec: exit 3, named once" || bad "adversary spec" "got $st: $(cat "${root}/err")"
echo "criteria" > "${proj}/specs/01-thing.md"
run_ws CLAUDE_STUB_WRITE="pkg/thing.go" -- red 09 s1 -- -p --model m "x" >/dev/null; st=$?
[[ $st -eq 0 ]] && ok "the test-files-only rule is the adversary's: red may still write a stub" || bad "red stub" "got $st: $(cat "${root}/err")"
calls="$(wc -l < "${CLAUDE_STUB_ARGV}")"; mkdir -p "${root}/nogit"
(cd "${root}/nogit" && RALPH_REPO_ROOT="${root}/nogit" PATH="${root}/bin:${PATH}" bash "${KIT_SCRIPTS}/claude-run.sh" adversary 09 s1 -- -p --model m "x" >/dev/null 2>"${root}/err"); st=$?
[[ $st -eq 2 && "$(wc -l < "${CLAUDE_STUB_ARGV}")" -eq "${calls}" ]] && grep -q "git work tree" "${root}/err" && ok "adversary outside a git work tree is refused before any call: what it wrote could not be told" || bad "adversary no git" "got $st: $(cat "${root}/err")"
[[ "$(grep '^is_test()' "${KIT_SCRIPTS}/claude-run.sh")" == "$(grep '^is_test()' "${KIT_SCRIPTS}/drift-check.sh")" && -n "$(grep '^is_test()' "${KIT_SCRIPTS}/claude-run.sh")" ]] && ok "claude-run.sh and drift-check.sh agree on what a test file is" || bad "is_test parity" "$(grep -h '^is_test()' "${KIT_SCRIPTS}/claude-run.sh" "${KIT_SCRIPTS}/drift-check.sh")"

# --- the token sentinel around every stage (scripts/token-sentinel.sh) ---
echo "claude-run.sh token cap"
# A copy of the scripts with a stub notify.sh: a breach tells the owner.
kitc="${root}/kitc/scripts"; mkdir -p "${kitc}"
cp "${KIT_SCRIPTS}"/{claude-run,token-sentinel,usage-lib,ralph-config}.sh "${kitc}/"
printf '#!/usr/bin/env bash\n[[ $1 == -t ]] && shift 2\nprintf "%%s\\n" "$*" >> "%s/notify"\n' "${root}" > "${kitc}/notify.sh"; chmod +x "${kitc}"/*.sh
export RALPH_TRANSCRIPT_DIR="${root}/projects"
run_cs() { (cd "${root}" && PATH="${root}/bin:${PATH}" bash "${kitc}/claude-run.sh" "$@" 2>"${root}/err"); }
rows="$(wc -l < "${RALPH_USAGE_LEDGER}")"
out="$(run_cr other 08 s1 -- -p --model m "x")"; st=$?
sid="$(argv_last | grep -oE -- '--session-id [0-9a-f-]{36}' | cut -d' ' -f2)"
[[ $st -eq 0 && -n "${sid}" ]] && ok "every session is launched with a fresh --session-id (the transcript the sentinel reads)" || bad "session id" "got $st: $(argv_last)"
[[ "$(argv_last)" == *" --session-id ${sid} --output-format json" ]] && ok "the id sits before --output-format, after everything else" || bad "id order" "$(argv_last)"
out="$(run_cr other 08 s1 -- -p --session-id abc-123 "x")"
[[ "$(grep -o -- '--session-id' <<<"$(argv_last)" | wc -l)" -eq 1 && "$(argv_last)" == *"--session-id abc-123"* ]] && ok "a caller's own --session-id is kept, not doubled" || bad "caller id" "$(argv_last)"
out="$(run_cr other 08 s1 -- -p --resume def-456 "x")"
[[ "$(argv_last)" != *"--session-id"* ]] && ok "a --resume <id> names the transcript already: no --session-id added" || bad "resume" "$(argv_last)"
row="$(tail -1 "${RALPH_USAGE_LEDGER}")"
[[ "${row}" == *'"cap": 3000000'* && "${row}" == *'"over_cap": false'* ]] && ok "a row under the cap says so: cap 3000000, over_cap false" || bad "row cap" "${row}"

rm -f "${root}/notify"; rows="$(wc -l < "${RALPH_USAGE_LEDGER}")"
out="$(RALPH_TOKEN_CAP=1000 run_cs other 08 s2 -- -p --model m "x")"; st=$?
[[ $st -eq 4 && "$out" == "the model said this" ]] && ok "a stage that finished over its cap (19510 > 1000): its text printed, exit 4" || bad "post-hoc breach" "got $st: $out / $(cat "${root}/err")"
row="$(tail -1 "${RALPH_USAGE_LEDGER}")"
[[ "$(wc -l < "${RALPH_USAGE_LEDGER}")" -eq $((rows+1)) && "${row}" == *'"over_cap": true'* && "${row}" == *'"cap": 1000'* && "${row}" == *'"exit": 4'* && "${row}" == *'"weighted": 19510'* ]] && ok "one row, from the envelope, marked over_cap with the cap and exit 4" || bad "post-hoc row" "${row}"
grep -q "other session for 08 s2 spent 19510 weighted tokens, past its cap of 1000" "${root}/notify" 2>/dev/null && grep -q "past its cap" "${root}/err" && ok "the owner is told, and so is the caller's stderr" || bad "post-hoc notify" "$(cat "${root}/notify" 2>&1) / $(cat "${root}/err")"
out="$(RALPH_TOKEN_CAP_OTHER=20000 RALPH_TOKEN_CAP=1000 run_cs other 08 s2 -- -p --model m "x")"; st=$?
[[ $st -eq 0 ]] && ok "RALPH_TOKEN_CAP_<STAGE> lifts one stage above the general cap" || bad "stage cap" "got $st: $(cat "${root}/err")"

rm -f "${root}/notify"; rows="$(wc -l < "${RALPH_USAGE_LEDGER}")"; start=$(date +%s)
out="$(CLAUDE_STUB_LEAK=5 RALPH_TOKEN_CAP=1000 RALPH_TOKEN_CAP_POLL=1 run_cs red 08 s3 -- -p --model m "x")"; st=$?
took=$(( $(date +%s) - start ))
[[ $st -eq 4 && $took -lt 8 ]] && ok "a session leaking while it runs is killed within a poll (${took}s, not 20): exit 4" || bad "live breach" "got $st after ${took}s: $out / $(cat "${root}/err")"
sleep 0.5; ! kill -0 "$(cat "${CLAUDE_STUB_ARGV}.pid" 2>/dev/null)" 2>/dev/null && ok "the session's process is gone" || bad "process" "pid $(cat "${CLAUDE_STUB_ARGV}.pid")"
row="$(tail -1 "${RALPH_USAGE_LEDGER}")"
[[ "$(wc -l < "${RALPH_USAGE_LEDGER}")" -eq $((rows+1)) && "${row}" == *'"stage": "red"'* && "${row}" == *'"over_cap": true'* && "${row}" == *'"weighted": 13525'* && "${row}" == *'"num_turns": 5'* ]] && ok "its row comes from the transcript: red, 5 turns, 13525 weighted, over_cap" || bad "live row" "${row}"
grep -q "red session for 08 s3" "${root}/notify" 2>/dev/null && ! grep -q "not recorded" "${root}/err" && ok "the owner is told once; no 'not recorded' warning for the missing envelope" || bad "live notify" "$(cat "${root}/notify" 2>&1) / $(cat "${root}/err")"
rm -f "${root}/notify"
out="$(CLAUDE_STUB_LEAK=5 RALPH_TOKEN_CAP=0 RALPH_TOKEN_CAP_POLL=1 timeout 4 bash -c 'cd "$0" && PATH="$1:$PATH" bash "$2/claude-run.sh" red 08 s4 -- -p --model m x' "${root}" "${root}/bin" "${kitc}" 2>/dev/null)"; st=$?
[[ $st -eq 124 ]] && ok "no cap: the sentinel reads nothing and the session runs on (ended here by the test's own timeout)" || bad "no cap" "got $st"
pkill -f "sleep 20" 2>/dev/null; unset RALPH_TRANSCRIPT_DIR

echo "usage-session.sh"
mkdir -p "${root}/repo" && ( cd "${root}/repo" && git init -q && git config user.email t@x && git config user.name t && git commit -q --allow-empty -m init )
# The client's directory name for a cwd: every non-alphanumeric character is '-'
# (2.1.289), so mktemp's /tmp/tmp.XXXX is -tmp-tmp-XXXX, not -tmp-tmp.XXXX.
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
tdir="${root}/projects/$(enc "${root}/repo")"; mkdir -p "${tdir}"
{ for i in 1 2 3; do printf '{"type":"assistant","message":{"model":"claude-opus-5","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":10000,"output_tokens":300}}}\n'; done
  printf '{"type":"user","message":{"content":"x"}}\n'; } > "${tdir}/sess-a.jsonl"
out="$(cd "${root}/repo" && RALPH_TRANSCRIPT_DIR="${root}/projects" bash "${KIT_SCRIPTS}/usage-session.sh" implement 08 s1 --since 0 2>&1)"
row="$(tail -1 "${RALPH_USAGE_LEDGER}")"
python3 - "$row" <<'PY' && ok "sums 3 assistant turns: output 900, cache_read 30000, ctx/turn 10000, weighted 8115" || bad "session row" "$row / $out"
import json,sys; d=json.loads(sys.argv[1])
assert d["stage"]=="implement" and d["num_turns"]==3 and d["output"]==900 and d["cache_read"]==30000
assert d["fixed_context_per_turn"]==10000 and d["weighted"]==15+3000+600+4500, d["weighted"]
PY

# An all-lowercase checkout path: the transcript dir and its lower-cased twin
# are the same directory, and each transcript must still be summed once.
lroot="$(mktemp -d /tmp/usage-lower.XXXXXX)"; lroot_lc="$(printf '%s' "${lroot}" | tr '[:upper:]' '[:lower:]')"
[[ "${lroot}" == "${lroot_lc}" ]] || { mv "${lroot}" "${lroot_lc}"; lroot="${lroot_lc}"; }
mkdir -p "${lroot}/repo" && ( cd "${lroot}/repo" && git init -q && git config user.email t@x && git config user.name t && git commit -q --allow-empty -m init )
ltdir="${root}/projects/$(enc "${lroot}/repo")"; mkdir -p "${ltdir}"
cp "${tdir}/sess-a.jsonl" "${ltdir}/sess-b.jsonl"
out="$(cd "${lroot}/repo" && RALPH_TRANSCRIPT_DIR="${root}/projects" bash "${KIT_SCRIPTS}/usage-session.sh" implement 08 s2 --since 0 2>&1)"
row="$(tail -1 "${RALPH_USAGE_LEDGER}")"
python3 - "$row" <<'PY' && ok "an all-lowercase checkout path sums each transcript once (3 turns, not 6)" || bad "lowercase path double count" "$row / $out"
import json,sys; d=json.loads(sys.argv[1]); assert d["num_turns"]==3 and d["output"]==900 and d["session_id"]=="sess-b", d
PY
rm -rf "${lroot}"

# The standing operator's sessions: cwd its kit checkout (not a git repository
# here, and with '.' and '_' in its path), one row per session, from that
# session's transcript only.
kit="${root}/ops.local/my_kit"; mkdir -p "${kit}" "${root}/projects/$(enc "${kit}")"
cp "${tdir}/sess-a.jsonl" "${root}/projects/$(enc "${kit}")/op-a.jsonl"
head -1 "${tdir}/sess-a.jsonl" > "${root}/projects/$(enc "${kit}")/op-b.jsonl"
out="$(cd "${root}" && RALPH_TRANSCRIPT_DIR="${root}/projects" bash "${KIT_SCRIPTS}/usage-session.sh" operator ops run-1 --root "${kit}" --session op-a 2>&1)"
row="$(tail -1 "${RALPH_USAGE_LEDGER}")"
python3 - "$row" <<'PY' && ok "--root and --session: an operator row from that session's transcript only, in a path with '.' and '_'" || bad "operator row" "$row / $out"
import json,sys; d=json.loads(sys.argv[1])
assert d["stage"]=="operator" and d["spec"]=="ops" and d["slice"]=="run-1" and d["session_id"]=="op-a" and d["num_turns"]==3, d
PY

echo "usage-report.sh"
out="$(bash "${KIT_SCRIPTS}/usage-report.sh" --spec 08 2>&1)"
[[ "$out" == *"08    red"* && "$out" == *"08    implement"* && "$out" == *"weighted total"* ]] && ok "reports both stages for spec 08" || bad "report" "$out"
out="$(bash "${KIT_SCRIPTS}/usage-report.sh" 2>&1)"
[[ "$out" == *"ops   operator"* ]] && ok "the operator is a stage of its own in the report" || bad "operator stage" "$out"
out="$(bash "${KIT_SCRIPTS}/usage-report.sh" --spec 99 2>&1)"; [[ "$out" == *"weighted total"* ]] && ok "empty selection still renders" || bad "empty" "$out"
out="$(bash "${KIT_SCRIPTS}/usage-report.sh" --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["08/implement"]["fixed"])')"; [[ "$out" == "10000" ]] && ok "--json exposes fixed context per turn" || bad "json" "$out"
echo "no leak"
# The scripts that source usage-lib run the project's own suite (ralph-iterate's
# suite_green, the red check). What the lib derives must not reach it.
n="$(cd "${root}" && env -u RALPH_USAGE_LEDGER RALPH_PROJECT_NAME=fixture bash -c ". ${kitc}/usage-lib.sh; env" | grep -c '^RALPH_USAGE_LEDGER=\|^RALPH_W_')"
[[ "${n}" -eq 0 ]] && ok "sourcing usage-lib exports nothing: a nested suite keeps its own HOME and ledger" || bad "export leak" "${n} variable(s) exported"
n="$(cd "${root}" && RALPH_USAGE_LEDGER="${root}/mine.jsonl" bash -c ". ${kitc}/usage-lib.sh; usage_py -c 'import os; print(os.environ[\"RALPH_USAGE_LEDGER\"], os.environ[\"RALPH_W_OUTPUT\"])'")"
[[ "${n}" == "${root}/mine.jsonl 5" ]] && ok "usage_py hands python the ledger path and the weights, and only python" || bad "usage_py env" "${n}"

echo "  ${pass} passed, ${fail} failed"; [[ $fail -eq 0 ]]
