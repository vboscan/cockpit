---
name: btw
description: Ask a side question in a new interactive Claude session, opened in a pane to the right (tmux split in the cockpit, cmux split otherwise). Replaces the built-in /btw overlay.
argument-hint: "<question>"
disable-model-invocation: true
---

Inside tmux or cmux this command is normally handled by the `UserPromptExpansion` hook in `~/.claude/settings.json` (`btw-side.sh hook`), which opens the side session and blocks this prompt. You are reading this because the hook did not handle it.

Pass the side question below, unchanged, on stdin to:

```sh
sh ~/.claude/skills/btw/btw-side.sh open ${CLAUDE_SESSION_ID} <<'BTW_QUESTION'
<the side question>
BTW_QUESTION
```

- If it succeeds, say in one line that the side session is open and carry on with what you were doing. Do not answer the question here.
- If it reports that there is no side pane to open, answer the question yourself, briefly and without tools, then carry on with what you were doing.

Side question: $ARGUMENTS
