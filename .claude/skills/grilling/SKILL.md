---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

## One question at a time (kit policy)

**Ask exactly one question per message, then stop and wait for the answer.** A
batch of questions is bewildering to answer and invites the user to skim: the
third question in a round gets a shorter answer than it deserves, and the
fourth gets none. One at a time is slower per question and faster to a decision
that actually holds.

The **frontier** is every decision whose prerequisites are already settled.
Working one at a time does not mean working at random: pick from the frontier
the question whose answer unblocks the most of what is still behind it, and ask
that one. A question whose answer depends on something still open is not on the
frontier and must not be asked yet.

Each answer reshapes the tree — recompute the frontier before choosing the next
question. Never bundle a second question into the same message as a
"while we're here", and never present a question as answered-by-implication of
the last one; if the last answer settled something else too, say so and move
the counter, don't ask about it.

Format a question like so:

```
📊 **Progress**: <answered so far> settled · 1 open now · ~<estimate> expected behind it

❓ **Q<n>** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>
```

## The progress counter (kit policy)

Every question opens with the counter line. The estimate is the size of the
unexplored tree as best you can see it, and it is revised every time. If it
changes by more than a couple, say why in a clause (a branch closed early, an
answer opened a new subtree). Never omit the line, even when the estimate is a
guess.

## Facts are yours, decisions are theirs

Finding _facts_ is your job, never the user's. When a question needs a fact from
the environment (filesystem, tools, etc.), look it up — or dispatch a sub-agent
when the search is broad — before asking. Don't block on it: an exploration
still running is an unsettled prerequisite, so ask a different frontier question
meanwhile rather than sitting idle. The _decisions_ are the user's: put each one
to them and wait.

The session is done when the frontier is empty: every branch of the design tree
visited, nothing left silently assumed. Do not act on it until the user confirms
you have reached a shared understanding.
