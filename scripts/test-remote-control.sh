#!/usr/bin/env bash
# Behavioural tests for the remote-control pane predicates in
# scripts/claude-session.sh.
#
# Why these exist: on 2026-09-01 the Ralph loop could not start a single
# iteration. Claude Code v2.1.25x stopped printing the `remote-control is
# active` transcript line the spawner polled for, and instead opened a
# CONFIRMATION DIALOG ("Remote Control … ❯ Continue"). The spawner waited 20s,
# printed `FAIL: remote control never activated in ralph-iter`, and
# ralph-driver.sh took that as a merit death — so the loop stopped dead with a
# green tree and nothing to look at. Same root cause broke
# `claude-session.sh new` by hand.
#
# The predicates are pulled out of cmd_new so they can be tested against real
# captured panes, exactly as pane_busy was after the same class of bug (see
# scripts/test-pane-busy.sh).
#
# Run: scripts/test-remote-control.sh   (exit 0 = all assertions passed)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/claude-session.sh
CLAUDE_SESSION_LIB_ONLY=1 source "${REPO_ROOT}/scripts/claude-session.sh"

pass=0
fail=0

# expect_active <desc> <want: yes|no> <pane>
expect_active() {
  local desc="$1" want="$2" pane="$3" got
  if rc_active "$pane"; then got=yes; else got=no; fi
  if [[ $got == "$want" ]]; then
    printf '  ok   — %-56s want=%s\n' "$desc" "$want"; pass=$((pass + 1))
  else
    printf '  FAIL — %-56s want=%s got=%s\n' "$desc" "$want" "$got"; fail=$((fail + 1))
  fi
}

# expect_dialog <desc> <want: yes|no> <pane>
expect_dialog() {
  local desc="$1" want="$2" pane="$3" got
  if rc_dialog_open "$pane"; then got=yes; else got=no; fi
  if [[ $got == "$want" ]]; then
    printf '  ok   — %-56s want=%s\n' "$desc" "$want"; pass=$((pass + 1))
  else
    printf '  FAIL — %-56s want=%s got=%s\n' "$desc" "$want" "$got"; fail=$((fail + 1))
  fi
}

# expect_url_ready <desc> <want: yes|no> <pane>
expect_url_ready() {
  local desc="$1" want="$2" pane="$3" got
  if rc_url_ready "$pane"; then got=yes; else got=no; fi
  if [[ $got == "$want" ]]; then
    printf '  ok   — %-56s want=%s\n' "$desc" "$want"; pass=$((pass + 1))
  else
    printf '  FAIL — %-56s want=%s got=%s\n' "$desc" "$want" "$got"; fail=$((fail + 1))
  fi
}

# expect_url <desc> <want-url> <pane>
expect_url() {
  local desc="$1" want="$2" pane="$3" got
  got=$(rc_url "$pane")
  if [[ $got == "$want" ]]; then
    printf '  ok   — %-56s url=%s\n' "$desc" "${want:-<none>}"; pass=$((pass + 1))
  else
    printf '  FAIL — %-56s want=%s got=%s\n' "$desc" "${want:-<none>}" "${got:-<none>}"; fail=$((fail + 1))
  fi
}

# real: the v2.1.251 dialog, captured verbatim from a live session on
# 2026-09-01. This is the pane the old poll timed out on.
DIALOG=$(cat <<'EOF'
 ▐▛███▛█   Claude Code v2.1.251
▝▜██████▀  Fable 5 · Claude Max
  ▝▝ ▝▝    ~/segundo

▎ Keep working from anywhere
▎ Check progress or reply to any session from the mobile app, desktop app, or claude.ai. To keep a session in this terminal only, run /remote-control

   Remote Control

   This session is available in the Claude mobile app and at https://claude.ai/code/session_01VVNVYrJD6zEpQi7ozEdrNY.

     Disconnect this session
     Show QR code  Scan with your phone to open this session
   ❯ Continue

   Enter to select · Esc to continue
EOF
)

# real: the same session after Esc — the prompt is back, and note the URL is
# GONE. This is why the URL must be read from the dialog, not afterwards.
DISMISSED=$(cat <<'EOF'
 ▐▛███▛█   Claude Code v2.1.251
▝▜██████▀  Fable 5 · Claude Max
  ▝▝ ▝▝    ~/segundo

▎ Keep working from anywhere
▎ Check progress or reply to any session from the mobile app, desktop app, or claude.ai. To keep a session in this terminal only, run /remote-control

                                                                              ● high · /effort
────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle) · install gh for PR status · ← for agents        /rc
EOF
)

# real: the SAME dialog on a session that has not yet registered with the
# backend, captured 2026-09-01. Note the wording: "and claude.ai/code." with no
# session URL at all. The dialog is up and blocking input, but there is nothing
# to read yet — matching the shared prefix and calling it ready is what produced
# `FAIL: no remote-control URL found in claude-agent`.
DIALOG_NO_URL=$(cat <<'EOF'
 ▐▛███▛█   Claude Code v2.1.252
▝▜██████▀  Fable 5 · Claude Max
  ▝▝ ▝▝    ~/segundo

   Remote Control

   This session is available in the Claude mobile app and claude.ai/code.

     Disconnect this session
     Show QR code  Scan with your phone to open this session
   ❯ Continue

   Enter to select · Esc to continue
EOF
)

# the pre-v2.1.25x transcript line the spawner used to wait for. Still accepted:
# a fix that only understands the new dialog would break every older client.
LEGACY=$(cat <<'EOF'
  /remote-control is active · Continue here, on your phone, or at https://claude.ai/code/session_01Lt31SNkZ3VAw5VgY2B1WUW

❯ Run one iteration per ralph/PROMPT.md.
  ⏵⏵ auto mode on · esc to interrupt
EOF
)

# a freshly-booted session that has NOT reached remote control yet
BOOTING=$(cat <<'EOF'
 ▐▛███▛█   Claude Code v2.1.251
▝▜██████▀  Opus 5 · Claude Max
  ▝▝ ▝▝    ~/segundo

────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
EOF
)

# the environment picker, which the spawner answers with Enter. It must NOT be
# mistaken for the confirmation dialog — sending Esc here cancels the picker.
PICKER=$(cat <<'EOF'
   Select remote environment

   ❯ Default
     Sandboxed

   Enter to select · Esc to cancel
EOF
)

echo "rc_active — has remote control come up? (a false 'no' stops the Ralph loop)"
expect_active "v2.1.251 confirmation dialog"                yes "$DIALOG"
expect_active "legacy 'remote-control is active' line"      yes "$LEGACY"
expect_active "dismissed dialog: /rc badge in status bar"   yes "$DISMISSED"
expect_active "booting session, not there yet"              no  "$BOOTING"
expect_active "environment picker is not activation"        no  "$PICKER"
expect_active "dialog before the session registered"        yes "$DIALOG_NO_URL"

echo
echo "rc_dialog_open — is a dialog waiting to be dismissed?"
expect_dialog "v2.1.251 confirmation dialog"                yes "$DIALOG"
expect_dialog "already dismissed"                           no  "$DISMISSED"
expect_dialog "legacy line is not a dialog"                 no  "$LEGACY"
expect_dialog "environment picker is a DIFFERENT dialog"    no  "$PICKER"
expect_dialog "unregistered dialog still blocks input"      yes "$DIALOG_NO_URL"

echo
# The spawner must wait for a pane that actually CARRIES the URL. In v2.1.25x
# remote control is already on at launch, so the `/rc` badge is present from the
# first poll — breaking the wait on "is it active?" exits before the dialog has
# rendered and the URL is never seen. That is a real failure, observed
# 2026-09-01: `FAIL: no remote-control URL found in claude-agent`.
echo "rc_url_ready — is a URL actually on screen yet? (badge alone is NOT)"
expect_url_ready "confirmation dialog carries the URL"      yes "$DIALOG"
expect_url_ready "legacy transcript line carries the URL"   yes "$LEGACY"
expect_url_ready "/rc badge alone — active, but NO url"     no  "$DISMISSED"
expect_url_ready "booting session"                          no  "$BOOTING"
expect_url_ready "environment picker"                       no  "$PICKER"
expect_url_ready "dialog is UP but names no URL yet"        no  "$DIALOG_NO_URL"

echo
echo "rc_url — the URL must be read while the dialog is still up"
expect_url "from the dialog"     "https://claude.ai/code/session_01VVNVYrJD6zEpQi7ozEdrNY" "$DIALOG"
expect_url "from the legacy line" "https://claude.ai/code/session_01Lt31SNkZ3VAw5VgY2B1WUW" "$LEGACY"
expect_url "none once dismissed"  ""                                                        "$DISMISSED"
expect_url "none from the unregistered dialog" ""                                           "$DIALOG_NO_URL"

echo
# The first-run trust dialog blocks EVERY new project — precisely when a kit
# install is being stood up. Captured 2026-09-03 from a real spawn into a
# freshly installed repo: the spawner reported "/remote-control not on input
# line", which ralph-driver.sh reads as a spawn failure and a merit stop, so the
# loop never starts and the message names the wrong cause.
TRUST=$(cat <<'EOF'
 Accessing workspace:
 /home/dev/claude_sandbox
 Quick safety check: Is this a project you created or one you trust? (Like your own code, a
 well-known open source project, or work from your team). If not, take a moment to review
 what's in this folder first.
 Claude Code'll be able to read, edit, and execute files here.
 Security guide
 ❯ No, exit
   Yes, I trust this folder
 Enter to confirm · Esc to cancel
EOF
)

expect_trust() {
  local desc="$1" want="$2" pane="$3" got
  if trust_dialog_open "$pane"; then got=yes; else got=no; fi
  if [[ $got == "$want" ]]; then
    printf '  ok   — %-56s want=%s\n' "$desc" "$want"; pass=$((pass + 1))
  else
    printf '  FAIL — %-56s want=%s got=%s\n' "$desc" "$want" "$got"; fail=$((fail + 1))
  fi
}

expect_prompt() {
  local desc="$1" want="$2" pane="$3" got
  if input_prompt_ready "$pane"; then got=yes; else got=no; fi
  if [[ $got == "$want" ]]; then
    printf '  ok   — %-56s want=%s\n' "$desc" "$want"; pass=$((pass + 1))
  else
    printf '  FAIL — %-56s want=%s got=%s\n' "$desc" "$want" "$got"; fail=$((fail + 1))
  fi
}

echo "trust_dialog_open — the first-run gate every NEW project hits"
expect_trust "fresh directory: trust dialog is up"          yes "$TRUST"
expect_trust "a normal session is not the trust dialog"     no  "$DISMISSED"
expect_trust "the rc dialog is a DIFFERENT dialog"          no  "$DIALOG"

echo
# THE CONTROL. The trust dialog draws its menu cursor as `❯` — the same glyph
# as the input prompt. A readiness check greping a bare `❯` therefore reports
# "ready" while a modal is up, and the spawner types a slash command into a
# menu. This assertion is the entire reason input_prompt_ready exists.
echo "input_prompt_ready — a dialog's ❯ cursor is NOT a prompt that takes text"
expect_prompt "trust dialog draws ❯ but accepts no text"    no  "$TRUST"
expect_prompt "a real session prompt is ready"              yes "$DISMISSED"

echo
echo "passed=$pass failed=$fail"
((fail == 0))
