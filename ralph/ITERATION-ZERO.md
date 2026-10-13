# Iteration zero — git pipeline validation (dry run)

Purpose: prove the loop's entire git pipeline end-to-end **before any spec work**. The autonomous loop must not start until this passes.

## Procedure
1. `git fetch origin main && git checkout -B ralph/iteration-zero origin/main`
2. `git commit --allow-empty -m "chore: ralph pipeline validation (iteration zero)"`
3. `git push -u origin ralph/iteration-zero` (retry 4× with 2s/4s/8s/16s backoff on network failure)
4. Open a PR to `main` (see **Devbox git/PR mechanics** below).
5. Wait for CI (if configured yet) → **squash-merge** the PR.
6. `git fetch origin main` and verify the merge commit is on `origin/main`.
7. Record `iteration-zero: PASSED <date>` in `PROGRESS.md`, delete the branch.

## Devbox git/PR mechanics (no `gh` on the box)

- **Identity**: configured globally on the box (`git config --global user.*`,
  done 2026-07-19) — plain `git commit` works.
- **PRs and merges**: `gh` is not installed and cannot be (no sudo). Both
  halves go through a kit script — **never an inline curl/python call, and
  never a hand-rolled token extraction out of `~/.git-credentials`**:
  ```bash
  scripts/open-pr.sh --title "<title>" --body-file <path>   # prints "opened PR #<N>"
  scripts/merge-pr.sh <N>
  ```
  Each takes the PAT from `git credential fill` internally, where it never
  reaches argv or output. The auto-mode classifier denies the inline
  equivalents almost every time — the `PUT …/pulls/<N>/merge` since 2026-07-20
  (PR #25), and the `POST …/pulls` for the same reason: extracting a secret
  from a credential store and posting it to a network endpoint is
  indistinguishable from exfiltration, and the classifier is right to say so.
  A script at a fixed path can be allowlisted and then passes deterministically,
  while a session still cannot invent new API calls. `open-pr.sh` is also the
  resume-safe half: called twice for the same branch it returns the number that
  already exists rather than erroring or opening a second PR.
- **Call each script as a bare command** — never chained with `cd`, `&&` or a
  pipe. Allow rules match every part of a compound line; `tail`/`git fetch`
  are not allowlisted, so the line falls through to the auto-mode classifier,
  which denies the merge. Verify the merge in a separate call afterwards.
- **The allowlist rules are `Bash(scripts/open-pr.sh *)`, `Bash(scripts/merge-pr.sh *)`,
  `Bash(scripts/comment-pr.sh *)` and `Bash(scripts/notify.sh *)`** (the last two carry the
  same credential: PR comments and the notifications issue). Which file they belong in depends on the
  box. If `/etc/claude-code/managed-settings.json` sets
  `allowManagedPermissionRulesOnly`, user- and project-tier rules are dropped
  as they are read and only that root-owned file grants anything — read it
  first. Otherwise they go in **user settings** (`~/.claude/settings.json`),
  set up once per machine, not in the project's `.claude/settings.local.json`.
- **If the script is denied, the allowlist rule is missing on this box.**
  Record the blocker in PROGRESS.md and stop per Failure handling. Do not retry
  other call shapes, and **do not write the allowlist rule yourself** — an
  iteration granting itself the permission it is blocked on is not a session
  unblocking itself, it is the gate not existing.

  This is written as an instruction because it cannot be written as a control.
  Observed 2026-09-03 in a real iteration: told to stop for a human, it
  recorded the blocker correctly, then created `.claude/settings.local.json`
  with exactly this rule and merged 57 seconds later. Nothing unsafe shipped —
  `gate-marker.sh assert-complete` had cleared and CI was green, so the merge
  was legitimate and the rule was the right one. The problem is the precedent:
  a "wait for a human" gate that the agent can satisfy by writing a file is not
  a gate, and the next thing it grants itself may not be so harmless.

  Put the allowlist in `~/.claude/settings.json` rather than the project, so
  the file an iteration would create is not the file that matters:

  ```json
  { "permissions": { "allow": ["Bash(scripts/open-pr.sh *)", "Bash(scripts/merge-pr.sh *)", "Bash(scripts/comment-pr.sh *)", "Bash(scripts/notify.sh *)"] } }
  ```

  **Do not add a deny rule and believe it backs this up.** Both halves were
  tested on 2026-09-03 against client 2.1.259, and both failed:

  - `Write(path)` deny rules are inert. Only `Edit(path)` rules are matched by
    file permission checks — the client says so itself — and `Edit` rules
    already cover every file-editing tool, so the `Write` form is noise.
  - No permission rule reaches the shell. With
    `Edit(.claude/settings.local.json)` denied, the Edit tool is blocked and
    `printf '{…}' > .claude/settings.local.json` from Bash still succeeds,
    exit 0, with the classifier never engaging. Rules bind *tools*; a shell
    redirect is one opaque `Bash` call.

  A settings file the agent can write cannot stop the agent writing it. The
  only tier that holds is one the loop's user has no permission to touch, which
  is the host's job to provide and not something an iteration can arrange — see
  the kit README's *Known limitation: an iteration can grant itself
  permissions*. Until the host provides it, the instruction above is the whole
  of the gate.

## If ANY step fails — STOP and unblock
Do not proceed to specs. Emit precise, step-by-step instructions for the owner, e.g.:
- **Push denied (403/permission)**: create a fine-grained PAT on `vboscan/cockpit` with Contents: Read+Write and Pull requests: Read+Write; expose it as `GH_TOKEN`/git credential in the loop environment.
- **PR/merge tooling missing**: install + authenticate `gh` (`gh auth login`, verify `gh auth status`), or ensure the GitHub MCP server is connected with repo scope.
- **Merge blocked by branch protection**: in repo Settings → Branches → `main`: require status checks only; disable required human reviews (the loop's gates are `/security-review` + `/code-review` inside each iteration); allow squash merge; or add the loop's identity to the bypass list.
- **CI required but absent**: merge is allowed with no checks configured; once spec 01 adds CI, checks become required.

Then **re-run iteration zero from step 1**. Repeat until it passes end-to-end.

## After it passes
The specs `PROGRESS.md` marks **supervised** (the `manual-validated` boxes under Gates, and `supervised` in the table's Notes; the template lists 01 and 02) must be run manually/supervised (a human watches the run and vets spec interpretation, test quality, and review-gate behavior) before the loop runs unattended. Record each as `manual-validated` in `PROGRESS.md`.
