#!/usr/bin/env bash
# ANCHOR: ralph-pane-busy — decide whether a Ralph iteration's tmux pane is
# still working. scripts/ralph-driver.sh polls this to know when an iteration
# has finished; a wrong answer is expensive in one direction and catastrophic
# in the other, which is why it lives in its own tested script.
#
#   scripts/pane-busy.sh            # reads the pane text on stdin
#   source scripts/pane-busy.sh     # defines pane_busy; no side effects
#
# exit 0 / return 0 = BUSY (an iteration turn is live or about to resume)
# exit 1 / return 1 = IDLE (no evidence of work; safe to consider finished)
#
# THE ASYMMETRY THAT SHAPES EVERY RULE HERE. A false "busy" costs wall-clock
# only: the driver waits out its TIMEOUT and the iteration still merges, so
# progress is unharmed. A false "idle" KILLS a live iteration mid-work and
# spends a no-progress strike; two in a row trip the driver's breaker and stop
# the loop (observed 2026-07-26 04:35 — both iterations were healthy). So every
# ambiguous state must resolve to BUSY, and a new "working" screen we forgot to
# teach this function is a loop-stopping bug, not a slow poll.
#
# Evidence, captured from Claude Code v2.1.217 on a 220-col pane. Busy if ANY:
#   - the status bar shows "esc to interrupt" — an active turn
#   - a live spinner "✻ Verbing… (12s · ↓ 1.2k tokens" — an active turn.
#     Finished turns render "✻ Verbed for 12s" with no "… (", so a stale
#     transcript line never matches.
#   - the status bar shows a background-job counter: "1 shell", "2 agents",
#     "1 task", "1 monitor" — the turn resumes when the job lands.
#   - "✻ Waiting for N background agents to finish" — the sub-agent gate path
#     (used while Fable quota is out; see the fable5 fallback note). With the
#     agent panel expanded, the bar shows NO counter and renders BELOW the
#     panel, so this whole-pane spinner is the only signal left.
#
# Two subtleties this file exists to get right, both pinned by
# scripts/test-pane-busy.sh:
#
#   1. The status bar is found by its OWN chrome (the ⏵⏵ mode line), not by a
#      fixed tail. An expanded agent panel renders beneath the bar, so a
#      "last N lines" window captures panel rows and misses the bar entirely —
#      exactly how a healthy iteration read as idle on 2026-07-26. Anchoring on
#      the mode line is immune to how tall the panel is.
#   2. Counters are trusted ONLY on that bar line, never in the transcript.
#      "N shell still running" persists as a transcript line after the job ends,
#      so a naive widen of the window resurrects finished work. The ❯ input
#      prompt is likewise NOT a signal — it renders mid-turn too.
set -uo pipefail

# pane_busy <pane-text> — return 0 (busy) / 1 (idle). Pure; no output.
pane_busy() {
  local pane=$1 bar
  # Anchor on the status/mode line itself rather than a line count.
  bar=$(grep -E '⏵⏵|auto mode on|accept edits|plan mode' <<<"$pane" | tail -1)
  # Unknown chrome (a screen without the mode line): fall back to the old
  # last-5-lines window rather than guess idle.
  [[ -z $bar ]] && bar=$(tail -n 5 <<<"$pane")

  grep -qi 'esc to interrupt' <<<"$bar" && return 0
  grep -qE '… \([0-9]+[ms]' <<<"$pane" && return 0
  # "← 1 agent" (2.1.296) is the bar's agents hint with remote control connected:
  # every kit session has it, idle or not. A real background agent beside it
  # makes "← 2 agents", and a shell its own counter; both still read busy.
  bar=${bar//← 1 agent/}
  grep -qE '[0-9]+ (shell|agent|task|monitor)' <<<"$bar" && return 0
  # Match up to "agent" only: the count drives pluralisation ("1 background
  # agent" vs "3 background agents to finish"), and a killed iteration on the
  # singular form is what took the loop down 2026-07-26 10:54.
  grep -qE '✻ Waiting for [0-9]+ background agent' <<<"$pane" && return 0
  return 1
}

# pane_limited <pane-text> — did this iteration die on a usage limit rather
# than on merit? Lives here, next to pane_busy, because it is the same kind of
# decision (classify a pane by its chrome) and because a function the driver
# defined privately could not be tested; see scripts/test-pane-busy.sh.
#
# return 0 = a real usage-limit banner is on screen (quota death, exit 2)
# return 1 = no banner (merit death, exit 1 — the supervisor will NOT relaunch)
#
# THE ASYMMETRY, mirroring pane_busy's. A false "limited" costs a probe-and-wait
# the pool answers immediately. A false "not limited" reports a quota death as
# merit, and the supervisor deliberately does not relaunch merit exits — so the
# loop stays down until a human notices. That is exactly what happened on
# 2026-07-30 13:38: the banner read "You've hit your **weekly** limit", the
# qualifier was not in the old `(session|usage)` allowlist, and a healthy loop
# sat dead for hours after the limit had already reset at 14:00.
#
# So the qualifier is matched as ANY word, not an allowlist. The banner's
# wording is Anthropic-side text that has now changed three times (session,
# usage, weekly) and will change again; an allowlist turns every new phrasing
# into a silent loop-stopping bug.
#
# The same lesson then repeated one line lower. Corroboration used to be a
# literal on '/upgrade to increase your usage limit' — the line that keeps prose
# merely DISCUSSING limits (this repo's own PROGRESS.md does) from reading as a
# quota death. On 2026-08-22 18:12 the banner dropped that line for
# '/usage-credits to finish what you're working on.', the corroboration failed,
# and the loop sat dead ~24h after its 18:40 reset.
#
# So corroboration is now the banner's OWN line first: "· resets <when>" is
# chrome the banner has carried through every rewording, and no prose about
# limits reproduces it. The call-to-action allowlist survives as a second net,
# for a banner that someday states no reset time — it can only ADD matches, so a
# future rewording of THAT line degrades to the first check rather than to
# "merit". Both nets missing means a pane nobody has seen: read as merit, which
# is the one outcome that needs a human anyway.
#
# NOTE: no fixture pins that second net — every banner captured so far carries
# "· resets", so deleting the line below leaves the suite green (mutation-
# checked 2026-08-23). It is kept deliberately, as retained behaviour rather
# than tested behaviour: this bug has stopped the loop twice, and the cost of a
# net that never fires is nil against another day of downtime.
pane_limited() {
  grep -qE "hit your [a-z]+ limit[^[:alnum:]]+resets" <<<"$1" && return 0
  grep -qE "hit your [a-z]+ limit" <<<"$1" \
    && grep -qE '/upgrade to increase your usage limit|/usage-credits|to continue after reset' <<<"$1"
}

# Executed, not sourced: read the pane from stdin so the driver (or a human
# debugging a snapshot) can pipe a capture straight in.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  pane_busy "$(cat)"
  exit $?
fi
