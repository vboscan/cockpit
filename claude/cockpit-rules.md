## Working inside the cockpit (tmux)

When `$VICKS_IN_COCKPIT` is set, this session runs in a tmux pane. Every terminal here runs inside tmux, and one terminal per cmux workspace also has a pinned banner pane, which may or may not be in this window. Show terminal work in tmux panes of this window: a tmux pane has no banner, `tmux capture-pane` reads just that pane, and tmux needs no skill loaded.

- **Sub-tasks worth watching** (test runs, builds, dev servers, log tails): one helper pane to the right of this one.
  - Open: `P=$(tmux split-window -h -d -t "$TMUX_PANE" -P -F '#{pane_id}')`
  - Run: `tmux send-keys -t "$P" '<cmd>; echo EXIT=$?; tmux wait-for -S <token>' Enter`, then `tmux wait-for <token>`
  - Read: `tmux capture-pane -p -t "$P" -S -50`
  - Reuse that pane for later commands, and `tmux kill-pane -t "$P"` once it stops being useful.
- **Etiquette:** never steal focus (`-d`), leave the banner pane (the one with `@vicks_dash`) alone if this window has it, and keep quick lookups in normal Bash.
- **A terminal that must not run in tmux:** start its shell with `VICKS_PLAIN=1`. It gets no tmux and no banner.
- **`/btw <question>`** opens a fork of this session in such a pane (`~/.claude/skills/btw`).
- cmux stays the tool for what a terminal pane cannot show: web pages, rendered markdown, diffs, sidebar status and notifications.
