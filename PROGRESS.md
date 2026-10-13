# PROGRESS — Ralph loop state

<!-- HOT PATH: read at the start of every iteration and re-sent on every turn (~300×).
     Every 1K tokens here costs ~30K weighted tokens per iteration. Size rules, enforced
     by scripts/hot-path-check.sh in preflight — unruled growth is a defect:
       Gates      ≤ 12 lines.
       Table      one row per spec that is not done; Notes ≤ 60 chars; single-space cells,
                  never padded for alignment; ≤ 1,200 tokens. Done rows move to
                  PROGRESS-archive.md in step 6.
       Log        newest 3 entries, ≤ 25 lines each; older entries move to
                  PROGRESS-archive.md in step 6.
     Whole file ≤ 2,000 tokens. The archive is cold: read it only to investigate. -->

Every iteration updates this file (`ralph/PROMPT.md` step 6). It is the loop's **only** cross-iteration memory: the **status table** is the index the front (`scripts/ralph-iterate.sh`) picks from, and `done` means **merged to the default branch**, never "the code is written".

## Gates

Owner gates are ticked by a human, never by an iteration. An unchecked box blocks the specs it names as `(blocks NN, MM)`; an unticked `spec NN manual-validated` stops an unattended run once NN is merged. `scripts/ralph-iterate.sh` reads both. A project with no owner gates keeps the first box and deletes the rest.

- [ ] iteration-zero: PASSED `<date>` (`ralph/ITERATION-ZERO.md`; PR #`<N>` squash-merged, merge commit verified on the default branch)
- [ ] spec 01 manual-validated
- [ ] spec 02 manual-validated

## Spec status

`Design-blocked: yes` without an adopted design handoff recorded here, or an unmet `Depends-on`, both mean **blocked** — the front skips to the next spec; `in-progress (slice K/M)` names the last slice merged. Statuses: `not-started` · `in-progress (slice N/M)` · `blocked` · `done` (archived).

| Spec | Status | Depends-on | Design-blocked | Notes |
|-|-|-|-|-|
| 01-CHANGEME | not-started | — | no | |

## Log

<!-- Newest first, newest 3 only. One entry per iteration, written in step 6 AFTER the PR
     exists so the number is real. Each entry: spec + slice, what changed, decisions, findings
     accepted (with the reason), next. Delegation line: literal marker `**Delegation**:` —
     `delegated <what> (<tier>)` or `skipped <what> because <reason>` (scripts/delegation-audit.sh). -->
