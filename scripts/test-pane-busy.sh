#!/usr/bin/env bash
# Behavioural tests for scripts/pane-busy.sh.
#
# pane_busy decides when a Ralph iteration is finished. Its one catastrophic
# failure mode is calling a LIVE iteration idle: the driver then kills it and
# spends a no-progress strike, and two in a row stop the loop. Every fixture
# below is a real or realistic "working" pane that must read BUSY, plus the
# negatives that a careless fix breaks — a genuinely finished pane (must read
# idle) and a completed job whose transcript line lingers (must NOT resurrect).
#
# The two `real:` fixtures are verbatim-shaped reconstructions of the panes that
# were misclassified as idle on 2026-07-26 (originals: .ralph/logs/iter-{1,2}-
# pane.txt, gitignored and ephemeral, so embedded here).
#
# Run: scripts/test-pane-busy.sh   (exit 0 = all assertions passed)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/pane-busy.sh
source "${REPO_ROOT}/scripts/pane-busy.sh"

pass=0
fail=0

# expect <description> <want: busy|idle> <pane-text>
expect() {
  local desc="$1" want="$2" pane="$3" got
  if pane_busy "$pane"; then got=busy; else got=idle; fi
  if [[ $got == "$want" ]]; then
    printf '  ok   — %-52s want=%s\n' "$desc" "$want"
    pass=$((pass + 1))
  else
    printf '  FAIL — %-52s want=%s got=%s\n' "$desc" "$want" "$got"
    fail=$((fail + 1))
  fi
}

sep='────────────────────────────────────────────────────────────'

echo "pane_busy — busy states (a false 'idle' here stops the loop)"

# real: iter-1, killed at 365s — parked on a Monitor-armed /code-review gate.
# The status bar carries the '1 monitor' counter.
expect "real iter-1: parked on '1 monitor' gate wait" busy "$(cat <<EOF
● I've reviewed the entire slice thoroughly. I'll now wait for the gate.

  Read 1 file

✻ Cooked for 3m 6s · 1 monitor still running

  4 tasks (0 done, 1 in progress, 3 open)
  ◼ Run /code-review gate (Fable 5 headless)
${sep}
❯
${sep}
  ⏵⏵ auto mode on · install gh for PR status · 1 monitor · ctrl+t to hide tasks · ← for agents · ↓ to manage
EOF
)"

# real: iter-2, killed at 665s — three review sub-agents mid-flight with the
# agent panel EXPANDED, so the mode line is not in the last 5 rows and the bar
# shows no counter. The whole-pane spinner is the only signal.
expect "real iter-2: 3 sub-agents, panel expanded" busy "$(cat <<EOF
● /verify complete and passing (36/36); tree clean. Now waiting on the three
  adversarial review agents to return their findings.

✻ Waiting for 3 background agents to finish

${sep}
❯ Continue with the iteration.
${sep}
  ⏵⏵ auto mode on (shift+tab to cycle) · install gh for PR status · ← for agents · ↓ to manage
  ● main
  ◯ general-purpose  Code-review bug hunt: materials core       3m 1s · ↓ 35.3k tokens
  ◯ general-purpose  Code-review bug hunt: wiring/contract      2m 51s · ↓ 55.9k tokens
  ◯ general-purpose  Spec-fidelity + standards review           2m 41s · ↓ 58.9k tokens
EOF
)"

# real: iter-1 of the post-fix run, killed at 695s — two of three gates had
# finished, so the spinner had dropped to the SINGULAR "1 background agent".
# The plural-only probe missed it and the driver killed a live iteration.
expect "real: down to '1 background agent' (singular)" busy "$(cat <<EOF
● Two of three reading gates are back clean. The bug-hunt gate is still running.
  I'll batch all fixes once it reports — pausing here until its completion.

✻ Waiting for 1 background agent to finish

  4 tasks (2 done, 1 in progress, 1 open)
  ◼ Run four gates (security, code, spec-fidelity, verify) + confirm
${sep}
❯
${sep}
  ⏵⏵ auto mode on (shift+tab to cycle) · install gh for PR status · ctrl+t to hide tasks · ← for agents · ↓ to manage
  ● main
  ◯ general-purpose  Code-review bug hunt gate                   4m 29s · ↓ 61.2k tokens
EOF
)"

expect "active turn: 'esc to interrupt' on the bar" busy "$(cat <<EOF
● Editing the repository…

${sep}
  ⏵⏵ auto mode on · esc to interrupt · ← for agents
EOF
)"

expect "live spinner with elapsed timer" busy "$(cat <<EOF
✻ Flummoxing… (1m 12s · ↓ 2.5k tokens)
${sep}
❯
${sep}
  ⏵⏵ auto mode on · ← for agents · ↓ to manage
EOF
)"

expect "backgrounded shell counter on the bar" busy "$(cat <<EOF
● Waiting for CI…
${sep}
  ⏵⏵ auto mode on · 1 shell · ← for agents · ↓ to manage
EOF
)"

expect "backgrounded agents counter on the bar" busy "$(cat <<EOF
● Fanning out reviewers…
${sep}
  ⏵⏵ auto mode on · 2 agents · ← for agents · ↓ to manage
EOF
)"

echo
# Client 2.1.296 (2026-10-11): with remote control on, the bar's agents hint
# carries a count, "← 1 agent", on every idle session — the connected remote
# client. A real background agent beside it makes two.
expect "2.1.296: a backgrounded shell beside the remote-control agent" busy "$(cat <<EOF
● Runner kicked. Now waiting in the background per the protocol.
  Ran 1 shell command
${sep}
❯
${sep}
  ⏵⏵ auto mode on · 1 shell · ← 1 agent · ↓ to manage
EOF
)"
expect "2.1.296: two agents on the bar, one is remote control" busy "$(cat <<EOF
● Dispatched the review.
${sep}
❯
${sep}
  ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents
EOF
)"

echo "pane_busy — idle states (a false 'busy' here only wastes wall-clock)"
expect "2.1.296: idle with remote control on ('← 1 agent')" idle "$(cat <<EOF
● The stop is classified and noted. Operator #2 now holds the run.
✻ Brewed for 59s · done 8:55 AM
${sep}
❯ ops status
${sep}
  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent
EOF
)"

expect "genuinely idle: finished turn, no job" idle "$(cat <<EOF
● Iteration complete — merge landed on origin/main, tree clean.

✻ Cogitated for 49s
${sep}
❯
${sep}
  ⏵⏵ auto mode on · install gh for PR status · ← for agents · ↓ to manage
EOF
)"

# The hazard a naive "widen the tail window" fix trips: a completed job's
# transcript line persists and must NOT be read as busy.
expect "stale 'N shell still running' in transcript" idle "$(cat <<EOF
● Ran 1 shell command
  ⎿  1 shell still running
● Iteration complete.

✻ Cogitated for 12s
${sep}
❯
${sep}
  ⏵⏵ auto mode on · ← for agents · ↓ to manage
EOF
)"

# Finished spinner is past tense ("Waited"/"Cogitated"), no "… (" — must be idle.
expect "finished spinner (past tense), no job" idle "$(cat <<EOF
● Done.

✻ Waited for 3m 6s
${sep}
❯
${sep}
  ⏵⏵ auto mode on · ← for agents · ↓ to manage
EOF
)"


# expect_limited <description> <want: limited|merit> <pane-text>
expect_limited() {
  local desc="$1" want="$2" pane="$3" got
  if pane_limited "$pane"; then got=limited; else got=merit; fi
  if [[ $got == "$want" ]]; then
    printf '  ok   — %-52s want=%s\n' "$desc" "$want"
    pass=$((pass + 1))
  else
    printf '  FAIL — %-52s want=%s got=%s\n' "$desc" "$want" "$got"
    fail=$((fail + 1))
  fi
}

echo
echo "pane_limited — a false 'merit' leaves the loop DOWN (no relaunch)"

# real: the 2026-07-30 13:38 death. This exact banner was scored as MERIT by the
# old (session|usage) allowlist, so the supervisor refused to relaunch and the
# loop stayed dead for hours after the limit reset at 14:00. The regression this
# whole section exists for.
expect_limited "real 2026-07-30: WEEKLY limit at submit" limited "$(cat <<EOF
❯ Run one iteration per ralph/PROMPT.md.

● I'll start by reading the loop entry point.

  Read 1 file, ran 1 shell command
  ⎿  You've hit your weekly limit · resets 2pm (UTC)
     /upgrade to increase your usage limit.

✻ Cogitated for 4s
${sep}
❯
${sep}
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
EOF
)"

# real: the 2026-08-22 18:12 death (.ralph/logs/iter-17-pane.txt). The banner
# kept its first line and replaced its trailing call to action: no '/upgrade'
# line at all, but a '/usage-credits' one and a "press ⏎ after reset" hint. The
# old corroborating grep was a literal on the '/upgrade' wording, so a textbook
# quota death scored as MERIT and the supervisor left a healthy loop down for
# ~24h after the 18:40 reset. Same class of bug as 2026-07-30, one line lower.
expect_limited "real 2026-08-22: /usage-credits banner at submit" limited "$(cat <<EOF
❯ Run one iteration per ralph/PROMPT.md.
  ⎿  You've hit your session limit · resets 6:40pm (UTC) · progress saved
     Press ⏎ to continue after reset
     /usage-credits to finish what you’re working on.

✻ Baked for 0s
${sep}
❯
${sep}
  ⏵⏵ auto mode on (shift+tab to cycle) · install gh for PR status · ← for agents
EOF
)"

# real: the 2026-07-30 02:19 death — the form the old pattern did catch.
expect_limited "real 2026-07-30: SESSION limit mid-iteration" limited "$(cat <<EOF
● Running the gates.
  ⎿  You've hit your session limit · resets 3am (UTC)
     /upgrade to increase your usage limit.
${sep}
❯
${sep}
  ⏵⏵ auto mode on · ← for agents
EOF
)"

expect_limited "plan-wide 'usage limit' form" limited "$(cat <<EOF
  ⎿  You've hit your usage limit · resets in 2 days
     /upgrade to increase your usage limit.
EOF
)"

# The point of matching the qualifier as ANY word: the banner's wording is
# Anthropic-side text that has already changed three times. A qualifier nobody
# has seen yet must still read as a quota death, never as merit.
expect_limited "unseen future qualifier still reads as a limit" limited "$(cat <<EOF
  ⎿  You've hit your monthly limit · resets 1 Aug
     /upgrade to increase your usage limit.
EOF
)"

# The same point one line lower, and the reason corroboration reads the banner's
# own line first: the call to action has now been reworded twice, so a form
# nobody has seen must still read as a quota death on the "· resets" clause
# alone. Mutation-checked — delete that first grep and this fixture fails.
expect_limited "banner with an unseen call to action" limited "$(cat <<EOF
  ⎿  You've hit your daily limit · resets 9am (UTC) · progress saved
     Buy more usage to keep going.
EOF
)"

# Negatives — the corroborating line is the guard. Without it, an iteration merely
# DISCUSSING limits (this repo's own PROGRESS.md prose does) must not be read as
# a quota death, which would make the driver yield to a supervisor that then
# probes a perfectly healthy pool forever.
expect_limited "prose about limits, no banner" merit "$(cat <<EOF
● PROGRESS.md records that iterations die when you hit your weekly limit,
  so the driver classifies a no-merge exit by grepping for the banner.
${sep}
❯
${sep}
  ⏵⏵ auto mode on · ← for agents
EOF
)"

expect_limited "/upgrade line alone, no banner" merit "$(cat <<EOF
● Someone typed /upgrade to increase your usage limit. earlier in the session.
${sep}
❯
${sep}
  ⏵⏵ auto mode on · ← for agents
EOF
)"

expect_limited "healthy finished iteration" merit "$(cat <<EOF
● Merged PR #59. Iteration complete.

✻ Baked for 12s
${sep}
❯
${sep}
  ⏵⏵ auto mode on · ← for agents
EOF
)"

echo
echo "passed $pass, failed $fail"
((fail == 0))
