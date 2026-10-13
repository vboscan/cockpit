#!/usr/bin/env bash
# Behavioural tests for token-sentinel.sh. No network and no model: transcripts
# are fixtures, notify.sh is a stub that records what it was told, and the
# watched command is a script that grows a transcript on a schedule.
set -uo pipefail
KIT_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0; root="$(mktemp -d)"; trap 'rm -rf "${root}"' EXIT
ok()  { pass=$((pass+1)); echo "  ok  — $1"; }
bad() { fail=$((fail+1)); echo "  FAIL — $1"; echo "         $2"; }

# --- fixture: a project dir with the sentinel, its library and a stub notify ---
P="${root}/proj"; mkdir -p "${P}/scripts" "${P}/.ralph"
cp "${KIT_SCRIPTS}"/{token-sentinel,usage-lib,ralph-config}.sh "${P}/scripts/"
printf '#!/usr/bin/env bash\n[[ $1 == -t ]] && { printf "%%s\\t" "$2" >> "%s/notify"; shift 2; }\nprintf "%%s\\n" "$*" >> "%s/notify"\n' "${root}" "${root}" > "${P}/scripts/notify.sh"
chmod +x "${P}/scripts/"*.sh
printf ': "${RALPH_PROJECT_NAME:=fixture}"\n' > "${P}/.ralph/config.sh"
export RALPH_USAGE_LEDGER="${root}/ledger.jsonl" RALPH_TRANSCRIPT_DIR="${root}/projects"
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
tdir="${RALPH_TRANSCRIPT_DIR}/$(enc "${P}")"; mkdir -p "${tdir}"
# turn [sidechain]: one assistant line — weighted 5 + 1000 + 200 + 1500 = 2705
turn() { printf '{"type":"assistant","isSidechain":%s,"message":{"model":"m","usage":{"input_tokens":5,"cache_creation_input_tokens":100,"cache_read_input_tokens":10000,"output_tokens":300}}}\n' "${1:-false}"; }
# ts <args…>: the sentinel in the fixture; exit code in $st, output in $out
ts() { out="$(cd "${P}" && "$@" 2>"${root}/err")"; st=$?; }
sentinel() { ts bash scripts/token-sentinel.sh "$@"; }
why() { echo "exit ${st}; out: ${out}; err: $(tail -2 "${root}/err")"; }
rows() { if [[ -f "${RALPH_USAGE_LEDGER}" ]]; then wc -l < "${RALPH_USAGE_LEDGER}"; else echo 0; fi; }
notes() { cat "${root}/notify" 2>/dev/null; }

echo "cap"
sentinel cap code-review
[[ $st -eq 0 && "${out}" == 3000000 ]] && ok "a headless stage defaults to RALPH_TOKEN_CAP (3M)" || bad "default cap" "$(why)"
sentinel cap implement
[[ "${out}" == 200000000 ]] && ok "the implementer defaults to RALPH_TOKEN_CAP_IMPLEMENT (200M)" || bad "implement cap" "$(why)"
RALPH_TOKEN_CAP_CODE_REVIEW_RELATIVE_TO_SPECS=7 sentinel cap code-review-relative-to-specs
[[ "${out}" == 7 ]] && ok "RALPH_TOKEN_CAP_<STAGE> overrides one stage (upper-case, '-' as '_')" || bad "override" "$(why)"
RALPH_TOKEN_CAP=0 sentinel cap red
[[ "${out}" == 0 ]] && ok "0 means no cap" || bad "no cap" "$(why)"
RALPH_TOKEN_CAP=lots sentinel check red 01 1 sid-x
[[ $st -eq 2 ]] && grep -q "not a number" "${root}/err" && ok "a cap that is not a number is a usage error, not a breach" || bad "bad cap" "$(why)"
sentinel check red 01
[[ $st -eq 2 ]] && ok "check without a session id is a usage error" || bad "usage" "$(why)"

echo "check"
{ turn; turn; turn; } > "${tdir}/sid-1.jsonl"
RALPH_TOKEN_CAP=10000 sentinel check red 01 1 sid-1
[[ $st -eq 0 && "${out}" == $'SPENT=8115\nCAP=10000' ]] && ok "under the cap: exit 0, SPENT= from the transcript (3 turns, 8115), CAP=" || bad "under" "$(why)"
[[ "$(rows)" -eq 0 && -z "$(notes)" ]] && ok "under the cap nothing is recorded and nobody is told" || bad "under side effects" "$(rows) rows; $(notes)"
RALPH_TOKEN_CAP=8000 sentinel check red 01 1 sid-1
[[ $st -eq 4 ]] && ok "over the cap: exit 4" || bad "over" "$(why)"
row="$(tail -1 "${RALPH_USAGE_LEDGER}" 2>/dev/null)"
python3 - "${row}" <<'PY' && ok "the breach is a ledger row: stage red, spec 01, slice 1, the session id, weighted 8115, cap 8000, over_cap true, exit 4" || bad "breach row" "${row}"
import json, sys; d = json.loads(sys.argv[1])
assert d["stage"] == "red" and d["spec"] == "01" and d["slice"] == "1" and d["session_id"] == "sid-1", d
assert d["weighted"] == 8115 and d["cap"] == 8000 and d["over_cap"] is True and d["exit"] == 4 and d["num_turns"] == 3, d
PY
grep -q "ralph token sentinel" "${root}/notify" && grep -q "red session for 01 1 spent 8115 weighted tokens, past its cap of 8000" "${root}/notify" && grep -q "RALPH_TOKEN_CAP_RED" "${root}/notify" && ok "the owner is told which stage, how much, the cap, and which variable raises it" || bad "notify" "$(notes)"
grep -q "past its cap" "${root}/err" && ok "and the same message is on stderr for the caller's log" || bad "stderr" "$(cat "${root}/err")"
rm -f "${root}/notify"; : > "${RALPH_USAGE_LEDGER}"

{ turn; turn true; } > "${tdir}/sid-2.jsonl"
RALPH_TOKEN_CAP=5000 sentinel check red 01 1 sid-2
[[ $st -eq 4 && "${out}" == *"SPENT=5410"* ]] && ok "a sub-agent's turns are spend: 2 turns = 5410, over a cap of 5000" || bad "sidechain" "$(why)"
: > "${RALPH_USAGE_LEDGER}"; rm -f "${root}/notify"
RALPH_TOKEN_CAP=0 sentinel check red 01 1 sid-1
[[ $st -eq 0 && "${out}" == *"CAP=none"* && "$(rows)" -eq 0 ]] && ok "no cap: exit 0, CAP=none, nothing recorded" || bad "cap 0" "$(why)"
sentinel check red 01 1 sid-none
[[ $st -eq 0 && "${out}" == *"SPENT=0"* ]] && ok "no transcript yet: a spend of 0, never an error" || bad "missing transcript" "$(why)"
mkdir -p "${root}/elsewhere/$(enc "${root}/other")"; { turn; } > "${root}/elsewhere/$(enc "${root}/other")/sid-3.jsonl"
RALPH_TRANSCRIPT_DIR="${root}/elsewhere" RALPH_TOKEN_CAP=100 sentinel check other 00 x sid-3 --root "${root}/other"
[[ $st -eq 4 && "${out}" == *"SPENT=2705"* ]] && ok "--root names the session's cwd when it is not the caller's" || bad "--root" "$(why)"
: > "${RALPH_USAGE_LEDGER}"; rm -f "${root}/notify"

echo "watch"
# grow <session-id> <turns> <seconds-between> [then…]: the watched command. It
# records its pid and a child's, prints a line, grows the transcript, then exits 7.
cat > "${root}/grow" <<GROW
#!/usr/bin/env bash
echo "\$\$" > "${root}/grow.pid"; sleep 300 & echo "\$!" > "${root}/grow.child"
echo "hello from the stage"
for ((i = 0; i < \$2; i++)); do echo '$(turn | tr -d '\n')' >> "${tdir}/\$1.jsonl"; sleep "\$3"; done
kill "\$(cat "${root}/grow.child")" 2>/dev/null; exit 7
GROW
chmod +x "${root}/grow"
RALPH_TOKEN_CAP=100000 RALPH_TOKEN_CAP_POLL=1 sentinel watch slice 02 1 sid-w1 -- "${root}/grow" sid-w1 3 0.2
[[ $st -eq 7 && "${out}" == "hello from the stage" ]] && ok "under the cap the command's output and exit code (7) are its own" || bad "passthrough" "$(why)"
[[ "$(rows)" -eq 0 && -z "$(notes)" ]] && ok "and nothing is recorded" || bad "watch side effects" "$(rows) rows; $(notes)"

start=$(date +%s)
RALPH_TOKEN_CAP=5000 RALPH_TOKEN_CAP_POLL=1 sentinel watch slice 02 1 sid-w2 -- "${root}/grow" sid-w2 4 1
took=$(( $(date +%s) - start ))
[[ $st -eq 4 ]] && ok "over the cap while running: exit 4" || bad "watch breach" "$(why)"
(( took < 4 )) && ok "the command was ended as soon as the transcript passed the cap (${took}s of a 4 s run)" || bad "watch timing" "took ${took}s"
sleep 0.5
! kill -0 "$(cat "${root}/grow.pid")" 2>/dev/null && ! kill -0 "$(cat "${root}/grow.child")" 2>/dev/null && ok "the command and its child process are gone" || bad "tree" "pid $(cat "${root}/grow.pid") child $(cat "${root}/grow.child")"
row="$(tail -1 "${RALPH_USAGE_LEDGER}" 2>/dev/null)"
[[ "${row}" == *'"stage": "slice"'* && "${row}" == *'"session_id": "sid-w2"'* && "${row}" == *'"over_cap": true'* ]] && grep -q "slice session for 02 1" "${root}/notify" && ok "the breach row and the notice name the stage, spec, slice and session" || bad "watch row" "${row} / $(notes)"
[[ "$(rows)" -eq 1 ]] && ok "one row, not one per poll" || bad "rows" "$(rows)"
rm -f "${root}/notify"; : > "${RALPH_USAGE_LEDGER}"

RALPH_TOKEN_CAP=0 RALPH_TOKEN_CAP_POLL=1 sentinel watch slice 02 1 sid-w3 -- "${root}/grow" sid-w3 3 0.1
[[ $st -eq 7 ]] && ok "no cap: the command runs to its end whatever it spends" || bad "watch no cap" "$(why)"
sentinel watch slice 02 1 sid-w4
[[ $st -eq 2 ]] && ok "watch without a command is a usage error" || bad "watch usage" "$(why)"

echo "report"
sentinel report code-review 03 2 123456 100000
[[ $st -eq 0 ]] && grep -q "code-review session for 03 2 spent 123456 weighted tokens, past its cap of 100000" "${root}/notify" && grep -q "RALPH_TOKEN_CAP_CODE_REVIEW" "${root}/notify" && ok "report: the notice for a breach the caller found itself" || bad "report" "$(why) / $(notes)"

echo "  ${pass} passed, ${fail} failed"; [[ $fail -eq 0 ]]
