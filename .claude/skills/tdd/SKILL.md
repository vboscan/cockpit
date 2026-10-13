---
name: tdd
description: Test-driven development for this repo, autonomous-loop ready. Use when implementing any spec or fixing bugs test-first — in Ralph-loop iterations (unattended) or interactive sessions. Enforces red-green with seams pre-agreed by the spec.
---

# Test-Driven Development

TDD is the red → green loop. This skill is the reference that makes that loop produce tests worth keeping: what a good test is, where tests go, the anti-patterns, and the rules of the loop. Every section applies on every cycle — consult them before and during the loop, not after.

Project context lives in `PLAN.md` (architecture/strategy), `AGENTS.md` (hard rules — rule 2: a spec's acceptance criteria ARE its tests), and `specs/00-conventions.md` (stack, test layout, determinism rules). Test names and interface vocabulary must match the domain language used there and in the spec.

## What a good test is

Tests verify behavior through public interfaces, not implementation details. Code can change entirely; tests shouldn't. A good test reads like a specification — "user can checkout with valid cart" tells you exactly what capability exists — and survives refactors because it doesn't care about internal structure.

See [tests.md](tests.md) for examples and [mocking.md](mocking.md) for mocking guidelines.

## Seams — where tests go

A **seam** is the public boundary you test at: the interface where you observe behavior without reaching inside. Tests live at seams, never against internals.

**Test only at pre-agreed seams.** In this repo, seams are pre-agreed **by the spec**, not by conversation:

- **Autonomous (Ralph loop) mode**: the current spec's **Deliverables** section defines the seams (endpoints, module interfaces, job contracts), and its **Acceptance criteria** define what must be observable at them. Before writing any test, list the seams derived from the spec at the top of the test file or PR description. Do not invent seams the spec doesn't imply; do not wait for a user — the spec is the agreement. If a needed seam is genuinely absent from the spec, that is a spec defect: record it in PROGRESS.md notes and test at the nearest spec-implied seam.
- **Interactive mode** (a human is present): write down the seams under test and confirm them before writing tests.

The project's typical seams, and what is never a seam, are listed under Testing in `specs/00-conventions.md`; read that before listing the seams. Universal never-seams: module privates, and persistence read raw when a repository or API path exists.

## Anti-patterns

- **Implementation-coupled** — mocks internal collaborators, tests private methods, or verifies through a side channel (querying the database instead of using the interface). The tell: the test breaks when you refactor but behavior hasn't changed.
- **Tautological** — the assertion recomputes the expected value the way the code does (`expect(add(a, b)).toBe(a + b)`, a snapshot derived by hand the same way, a constant asserted equal to itself), so it passes by construction and can never disagree with the code. Expected values must come from an independent source of truth — a known-good literal, a worked example, the spec's acceptance criteria.
- **Horizontal slicing** — writing all tests first, then all implementation. Bulk tests verify _imagined_ behavior: you test the _shape_ of things rather than user-facing behavior, the tests go insensitive to real changes, and you commit to test structure before understanding the implementation. Work in **vertical slices** instead — one test → one implementation → repeat, each test a **tracer bullet** that responds to what the last cycle taught you.

<!-- HOT PATH (README "Hot path"): loaded every iteration; budget ≤ 1,500 tokens. -->

## The red session (kit protocol)

`/tdd red <spec> <slice>` runs in a fresh headless session on `RALPH_RED_MODEL`, never the implementer.
It reads the spec, `specs/00-conventions.md`, `PLAN.md`, `AGENTS.md` Part B; writes **one failing
acceptance test per criterion** (`TestAC<n>_…`, concrete inputs and expected outputs from the spec, never
recomputed the way the code would); writes compile-only stubs for the seams the Deliverables name (a stub
that passes a test is a red-phase bug); writes `ralph/plan-<spec>-<slice>.md` (restatement, edge cases,
files to touch, test-per-criterion table). It can edit files and nothing else — no toolchain, no git — so
the coordinator (`scripts/ralph-iterate.sh`) compiles the tests, sees the suite fail and commits
`checkpoint(red)`; a red that does not compile or does not fail is sent back. Acceptance tests are the spec made executable, so writing them first
is not horizontal slicing; the implementer's tracer-bullet tests at green are additions, one per cycle.

The implementer never edits a red test: amendments carry a `Test-Amendment:` trailer, and a red test
that contradicts the spec is escalated, not fixed.

## Rules of the loop

- **Red before green.** Write the failing test first, **run it, and observe it fail** — a test that was never seen red proves nothing. Then write only enough code to pass it. Don't anticipate future tests or add speculative features (AGENTS.md rule 9).
- **One slice at a time.** One seam, one test, one minimal implementation per cycle. Order slices by the spec's acceptance criteria; every criterion ends up with at least one test that cites it (a comment naming the criterion number is enough).
- **Deterministic tests only.** No wall-clock, randomness, or real network without injection (`specs/00-conventions.md`) — inject clocks, use the LLM FakeProvider, testcontainers for the DB.
- **Refactoring is not part of the loop.** It belongs to the review stage — the `/code-review`, `/code-review-relative-to-specs`, and `/security-review` gates that run before the PR — not the red → green implementation cycle.
