---
name: agy-delegation
description: Dispatch mechanical sub-tasks to Antigravity (headless agy) per AGENTS.md rule 8. Use when delegating implementation work to another coding agent, when choosing a model tier for a mechanical task, or when a dispatched agy task needs verification or its outcome recorded.
---

# Antigravity dispatch (`scripts/agy-task.sh`)

Dispatch = `scripts/agy-task.sh [-m "<model label>"] "<task prompt>"` from the
repo. Devbox-only (marker-file enforced); transcript lands in `.agy/logs/`.

## What may be dispatched

Mechanical work only (AGENTS.md rule 8): scaffolding, renames, fixtures,
boilerplate, mass edits with a crisp spec. In Ralph iterations, only **after**
the failing tests exist — never dispatch test-writing, design, debugging, or
security-sensitive code. Review gates apply to the diff regardless of author.

## Choosing the path

1. Read the **Standing conclusions** and recent rows in
   [docs/delegation-ledger.md](../../../docs/delegation-ledger.md) for this
   task type; a recorded promotion overrides the defaults below.
2. Defaults: `$RALPH_AGY_MODEL` (`.ralph/config.sh`; the kit ships `Gemini 3.8 Flash (High)`)
   — pass `-m` only to step DOWN to `(Medium)` for pure volume work, or when the task spans many files or is
   judgment-adjacent; agy `Sonnet 4.6` for mechanical-but-needs-judgment work
   worth keeping off the Claude pool (ledger-watched — it drains agy's
   Claude/GPT pool); don't dispatch what needs a frontier model — do it here.
   (`Gemini 3.1 Pro` demoted 2026-07-21: benchmark-inferior to 3.6 Flash;
   returns only on ledger evidence.) Exact labels: `agy models` — they must
   match verbatim or dispatch fails. agy quota is separate from Claude Code
   quota (two agy pools: Gemini vs Claude/GPT; check `/usage` in the agy TUI).

## Writing the dispatch prompt

- State the deliverable as files + acceptance ("create X containing Y; the
  existing tests in Z must pass"), not intentions.
- Demand a terse reply contract: "Reply with ONLY the list of files changed."
  The transcript is for auditing; your context shouldn't pay for prose.
- The script prepends the AGENTS.md-obedience preamble — don't repeat it.

## After dispatch — non-negotiable

1. **Verify on disk** (`git status` / `git diff` / run the tests). agy's
   print mode denies un-granted actions silently and its exit codes are
   unreliable — a "DONE" reply with exit 0 proves nothing, and a nonzero
   exit can accompany a good run. The diff is the only truth.
2. Run the normal review gates on the diff (independent review session, never
   inline — AGENTS.md rule 8).
3. Append the outcome row to `docs/delegation-ledger.md` (columns and
   verdict definitions are in the ledger header).

## Permission model / troubleshooting

Auto-mode equivalent, no blanket approval: sandboxed shell (`--sandbox`,
auto-runs, network OK, writes stay in the sandbox overlay), real file edits
via repo-scoped `write_file`/`edit_file` grants in
`~/.gemini/config/projects/default-cli-project.json`, everything else denied.

- Script errors `write_file(...) missing` → grants absent; a human adds them
  (docs/devbox.md §7) — Claude Code's classifier blocks agents from editing
  another agent's grants.
- Writes silently ignored in a fresh directory → workspace not trusted; a
  human answers agy's trust dialog once (`trustedWorkspaces` in
  `~/.gemini/antigravity-cli/settings.json`).
- Multi-turn follow-up on the same task: `agy -c -p "..."` continues the
  last conversation cheaply.
