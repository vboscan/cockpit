# PROGRESS archive — cold storage

**Not on the hot path**. Nothing reads this file at the start of an iteration. Step 6 moves
here: spec rows once they are `done` (with the merged PR numbers), and iteration-log entries older than
the newest three. Append-only. `scripts/progress-sync.sh` reads the done table below alongside
`PROGRESS.md` when checking the statuses against git.

## Done specs

| Spec | Merged PRs | Done on |
|-|-|-|

## Older log entries

<!-- Newest first, moved verbatim from PROGRESS.md. -->
