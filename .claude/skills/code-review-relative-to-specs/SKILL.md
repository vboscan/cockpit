---
name: code-review-relative-to-specs
description: Two-axis review of the changes since a fixed point — Standards (does the code follow AGENTS.md and specs/00-conventions.md?) and Spec (does the code faithfully implement the current specs/NN spec, including acceptance-criteria→test mapping and Non-goals?). Runs both reviews in parallel sub-agents and reports them side by side. Complements the built-in /code-review (bug hunting) — run both as Ralph-loop gates before every PR.
---

Two-axis review of the diff between `HEAD` and a fixed point:

- **Standards** — does the code conform to this repo's documented standards (`AGENTS.md` hard rules, `specs/00-conventions.md`, `CLAUDE.md`)?
- **Spec** — does the code faithfully implement the current spec (`specs/NN-*.md`), with every acceptance criterion test-proven and every Non-goal respected?

Both axes run as **parallel sub-agents** so they don't pollute each other's context, then this skill aggregates their findings. Per AGENTS.md Part A rule 8 (model allocation): review sub-agents run on the strongest available model — never downgrade review to a cheap tier, and never let a model review only its own tier's output.

## Process

### 1. Pin the fixed point

- **Autonomous (Ralph loop) mode**: the fixed point is the merge-base with the default branch — use `origin/main`. No user confirmation needed.
- **Interactive mode**: whatever the user said — a commit SHA, branch name, tag, `HEAD~5`. If they didn't specify one, ask.

Capture the diff command once: `git diff <fixed-point>...HEAD` (three-dot, so the comparison is against the merge-base). Also note the list of commits via `git log <fixed-point>..HEAD --oneline`.

Before going further, confirm the fixed point resolves (`git rev-parse <fixed-point>`) and the diff is non-empty. A bad ref or empty diff should fail here — not inside two parallel sub-agents.

### 2. Identify the spec source

1. **Autonomous mode**: the spec is the current iteration's `specs/NN-*.md` — identified from the branch name, the commit messages, or the in-progress row in `PROGRESS.md`. It always exists; a loop iteration without a locatable spec is itself a finding (report and stop).
2. **Interactive mode**: a path the user passed, or a spec under `specs/` matching the branch/feature; if none is found, ask. If the user says there isn't one, the **Spec** sub-agent skips and reports "no spec available".

Always read `specs/00-conventions.md` alongside the spec — it defines the shared acceptance conventions every spec inherits.

### 3. Identify the standards sources

This repo's standards sources, in authority order: `AGENTS.md` (Part A rules 1–8, Part B rules 9+), `specs/00-conventions.md` (stack/test/error/ID conventions), `CLAUDE.md`. Include all three.

On top of the repo standards, the Standards axis always carries the **smell baseline** below — a fixed set of Fowler code smells (_Refactoring_, ch.3) that applies even when a repo documents nothing. Two rules bind it:

- **The repo overrides.** A documented repo standard always wins; where it endorses something the baseline would flag, suppress the smell. (E.g. AGENTS.md Part A rule 2 already bans speculative generality and rule 4 bounds ceremony — cite the rule, not the smell, when both apply.)
- **Always a judgement call.** Each smell is a labelled heuristic ("possible Feature Envy"), never a hard violation — and, like any standard here, skip anything tooling already enforces (TypeScript strict, lint).

Each smell reads *what it is* → *how to fix*; match it against the diff:

- **Mysterious Name** — a function, variable, or type whose name doesn't reveal what it does or holds. → rename it; if no honest name comes, the design's murky.
- **Duplicated Code** — the same logic shape appears in more than one hunk or file in the change. → extract the shared shape, call it from both.
- **Feature Envy** — a method that reaches into another object's data more than its own. → move the method onto the data it envies.
- **Data Clumps** — the same few fields or params keep travelling together (a type wanting to be born). → bundle them into one type, pass that.
- **Primitive Obsession** — a primitive or string standing in for a domain concept that deserves its own type. → give the concept its own small type.
- **Repeated Switches** — the same `switch`/`if`-cascade on the same type recurs across the change. → replace with polymorphism, or one map both sites share.
- **Shotgun Surgery** — one logical change forces scattered edits across many files in the diff. → gather what changes together into one module.
- **Divergent Change** — one file or module is edited for several unrelated reasons. → split so each module changes for one reason.
- **Speculative Generality** — abstraction, parameters, or hooks added for needs the spec doesn't have. → delete it; inline back until a real need shows.
- **Message Chains** — long `a.b().c().d()` navigation the caller shouldn't depend on. → hide the walk behind one method on the first object.
- **Middle Man** — a class or function that mostly just delegates onward. → cut it, call the real target direct.
- **Refused Bequest** — a subclass or implementer that ignores or overrides most of what it inherits. → drop the inheritance, use composition.

### 4. Spawn both sub-agents in parallel

Send a single message with two `Agent` tool calls. Use the `general-purpose` subagent for both.

**Standards sub-agent prompt** — include:

- The full diff command and commit list.
- The list of standards-source files from step 3, **plus the smell baseline pasted in full** — the sub-agent has no other access to it.
- The brief: "Report — per file/hunk where relevant — (a) every place the diff violates a documented standard: cite the standard (file + the rule); and (b) any baseline smell you spot: name it and quote the hunk. Distinguish hard violations from judgement calls — documented-standard breaches can be hard, but baseline smells are always judgement calls, and a documented repo standard overrides the baseline. Skip anything tooling enforces. Under 400 words."

**Spec sub-agent prompt** — include:

- The diff command and commit list.
- The path to the spec and to `specs/00-conventions.md`.
- The brief: "Report: (a) each numbered acceptance criterion → the test(s) in the diff that prove it, flagging criteria with no test or a test that doesn't actually verify the criterion; (b) requirements the spec asked for that are missing or partial; (c) behaviour in the diff the spec didn't ask for — check the spec's **Non-goals** section explicitly; building a non-goal is a hard finding (AGENTS.md Part A rule 5); (d) requirements that look implemented but where the implementation looks wrong. Quote the spec line for each finding. Under 400 words."

If the spec is missing (interactive mode only), skip the Spec sub-agent and note this in the final report.

### 5. Aggregate

Present the two reports under `## Standards` and `## Spec` headings, verbatim or lightly cleaned. Do **not** merge or rerank findings — the two axes are deliberately separate (see _Why two axes_).

End with a one-line summary: total findings per axis, and the worst issue _within each axis_ (if any). Don't pick a single winner across axes — that's the reranking the separation exists to prevent.

**Autonomous mode disposition**: findings are failing tests (CLAUDE.md rule 1) — fix them, or record explicit acceptance with a reason in `PROGRESS.md`. No third option; the iteration does not proceed to PR with open findings.

## Why two axes

A change can pass one axis and fail the other:

- Code that follows every standard but implements the wrong thing → **Standards pass, Spec fail.**
- Code that does exactly what the issue asked but breaks the project's conventions → **Spec pass, Standards fail.**

Reporting them separately stops one axis from masking the other.
