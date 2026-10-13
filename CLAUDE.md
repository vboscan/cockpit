# CLAUDE.md

**Read `AGENTS.md` — all shared rules live there.** Claude-specific additions:

1. Before marking any spec done: run `/security-review` AND `/code-review` AND `/code-review-relative-to-specs` (standards + spec-fidelity axes) AND `/verify` (drive the changed behavior end-to-end). Findings = failing tests; fix them or record explicit acceptance (with reason) in PROGRESS.md. No third option. Implement test-first via the repo `tdd` skill (seams pre-agreed by the spec).
2. Model allocation (details: AGENTS.md Part A rule 8): the loop's main session implements on `claude-opus-5-5` — including writing all tests and running `/verify` inline; the three reading gates run headless on `claude-fable-5-1` (`claude -p --model claude-fable-5-1 "/<gate>"`), falling back to the implementer tier at `xhigh` in independent sessions when the review tier is unavailable. Review is always independent of the implementing session, never inline.
3. Ralph loop entry point: `ralph/PROMPT.md`. Iteration zero (`ralph/ITERATION-ZERO.md`) must pass before any spec work.
   **If this project is not yet defined — `bootstrap.sh --ready .` fails, or `AGENTS.md` still says CHANGEME — say so and stop.** A human runs `/ralph-init` to fill in `.ralph/config.sh`, Part B, `specs/` and the PROGRESS.md table. Never draft them unprompted in a loop iteration: a session that writes its own acceptance criteria is grading itself against a standard it invented, and every gate downstream inherits it.
4. After each merged iteration: send the non-blocking notification via `scripts/notify.sh` (a comment on the repo's notifications issue) (spec, summary, PR link, ready-to-paste "explain + manual test instructions" prompt).

<!--
  Project-specific additions go below. Examples from the project this kit was
  extracted from, kept as a shape to copy rather than rules to inherit:

  - All UI work: use the frontend-design skill; match the adopted design
    handoff in `design/`; no generic AI aesthetics.
  - Mechanical work is pool-first: a separate-quota headless agent
    (scripts/agy-task.sh) → cheap subagents → inline.
-->
