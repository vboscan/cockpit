---
name: ralph-init
description: Turn a freshly installed ralph-kit into a project the loop can actually run — interviews the human, then drafts .ralph/config.sh, the CI workflow, AGENTS.md Part B, specs/ and the PROGRESS.md table. Use in a new repo where bootstrap.sh --ready fails.
disable-model-invocation: true
---

# ralph-init

`install.sh` leaves a repo that is scaffolded but not *defined*. Five things
carry no default anyone can guess, and the loop reads all five as data:

| Artefact | Why it cannot be defaulted |
|---|---|
| `.ralph/config.sh` | the project's name and its real test/lint/typecheck commands |
| `AGENTS.md` Part B | the stack and domain rules a reviewer grades a diff against |
| `specs/00-conventions.md` + `specs/NN-*.md` | acceptance criteria — the loop's definition of done |
| `.github/workflows/ci.yml` | seeded once from the template's guessed stack and never regenerated; CI is where "done" is decided |
| the `PROGRESS.md` status table | the only index `scripts/ralph-iterate.sh` picks from; a wrong table sends iterations into finished work |

This skill produces drafts of those five. It does not start the loop.

## The one rule that shapes everything else

**You may draft the acceptance criteria. You may not decide them.**

The kit's central contract is that a spec's acceptance criteria *are* its
tests — that is what `/code-review-relative-to-specs` grades and what makes
"done" objective. An agent that authors both the criteria and the tests is
grading itself against a standard of its own invention, and every gate
downstream inherits it. So every criterion goes to the human as a question with
your recommendation attached, and you wait for the answer.

`disable-model-invocation` is set for the same reason: an unattended iteration
must not be able to invoke this and write its own definition of done.

## Procedure

1. **Read before asking.** `grilling`'s rule holds: if a fact is discoverable
   in the repo — language, package manager, test runner, existing modules,
   README, design docs — look it up. Only decisions go to the human.

2. **Run `grill-with-docs`.** The interview establishes the domain and the
   plan; `CONTEXT.md` and `docs/adr/` capture them as they crystallise. Do not
   skip to drafting because the project looks obvious: the questions are how
   the human's intent gets into the artefacts at all.

3. **Draft `.ralph/config.sh`.** Set `RALPH_PROJECT_NAME` and the three stack
   commands to what this repo actually runs. Verify each by running it — a
   command that does not exist is worse than none, and `RALPH_TEST_CMD` left
   *empty* is worse still: `install.sh` turns an empty value into a CI step
   that echoes "skipped" and passes, so the suite reports green having run
   nothing and "done = tests green in CI" becomes vacuously true.

4. **Update `.github/workflows/ci.yml` to match.** `install.sh` baked the
   template's guessed commands into the `project` job once, at seed time, and
   nothing regenerates the file — it is per-project so an upgrade cannot clobber
   a pipeline someone wrote. So editing `.ralph/config.sh` in step 3 and
   stopping there leaves CI running the *previous* stack's commands. Put the
   real commands in the job, and add the toolchain setup they need (the
   template ships a commented Node/pnpm block as a shape to copy). Leave the
   kit-owned `loop-tooling` job alone.

   `bootstrap.sh --ready` checks this, so drift here fails the readiness gate
   rather than surfacing as a baffling CI run — but fix it because CI is the
   loop's definition of done, not because a checker says so.

5. **Draft `AGENTS.md` Part B.** Replace every `CHANGEME`. Part A is the loop
   protocol and is portable — do not edit it. Each rule in Part B must be
   checkable by a reviewer who has read only the spec and the diff; a rule that
   cannot fail a diff is decoration.

6. **Draft the specs.** `specs/00-conventions.md` for shared conventions, then
   numbered specs whose acceptance criteria map one-to-one onto tests. Size
   each against the loop's slicing rule: a slice's *build* must fit half a
   usage window, because gates, fix rounds, CI and the merge take the other
   half. Fewest slices that individually fit — each extra slice pays the whole
   tail again. Every spec needs Non-goals; scope creep fails review. Each spec
   stays under 900 tokens (`scripts/hot-path-check.sh`) — the reasoning goes in
   an ADR, not the spec. `00-conventions.md` names which specs get an
   adversarial-additions session and which packages the mutation floor covers.

7. **Draft the `PROGRESS.md` table.** One row per spec, all `not-started`,
   single-space cells (never padded), Notes ≤ 60 chars. Mark the first two as
   requiring supervised runs — they establish the CI and the data layer
   everything later is graded against. Set `RALPH_SUITE_MARKER` in
   `.ralph/config.sh` to the file whose presence means the suite exists.

8. **Stop.** Print what you drafted and what you assumed, then hand back:

   - `bootstrap.sh --ready .` — the objective check that content exists
   - `bash scripts/preflight.sh`
   - `ralph/ITERATION-ZERO.md`, run **supervised**
   - specs 01 and 02 **supervised**, before anything runs unattended
   - only then: `tmux new -As ralph-<project> 'scripts/ralph-heartbeat.sh'` (the name is `RALPH_TMUX_SESSION`; per project, so two loops on one box do not collide)

   Do not run any of them. `--ready` passing means the files exist and are not
   placeholders; it says nothing about whether the criteria are *right*, and a
   human reading them is the only thing that does.
