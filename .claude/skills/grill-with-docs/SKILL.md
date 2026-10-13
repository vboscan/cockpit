---
name: grill-with-docs
description: A relentless interview to sharpen a plan or design, which also creates docs (ADRs and glossary) as we go. Use when stress-testing a plan before building and the domain model should be written down as it crystallises.
disable-model-invocation: true
---

# Grill with docs

Two skills, run together: the interview that pins the decisions down, and the
discipline that writes them where they survive the session.

Invoke the `grilling` skill and the `domain-modeling` skill, and hold both sets
of instructions at once for the whole session. Neither replaces the other:

- `grilling` drives the interview — one question at a time, a recommended
  answer with each, facts looked up in the repo rather than asked, decisions
  put to the human and waited on.
- `domain-modeling` captures the result as it emerges — `CONTEXT.md` for the
  ubiquitous language, `docs/adr/` for the decisions and the alternatives that
  lost. Write each one the moment it crystallises, not in a batch at the end:
  the reasoning is what decays, and it decays inside the same session.

`disable-model-invocation` is set deliberately. This skill only runs when a
human types it. An unattended session must never be able to start an interview
it is also answering — the decisions belong to a person, which is the entire
premise of `grilling`.

Adapted from https://github.com/mattpocock/skills
(`skills/engineering/grill-with-docs`).
