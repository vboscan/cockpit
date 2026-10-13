# Progress Log

- 2026-07-30 · spec 21-iac-pulumi · PR #50 · **Provisioned the storage buckets.**

  The stack export is regenerated with:

  ```bash
  # regenerate the Pulumi stack export
  pulumi stack export > infra/stack.json
  ```

  **Delegation**: delegated the stack export script (Gemini 3.6 Flash Medium).

- 2026-07-29 · spec 06-llm-router-budget · PR #49 · **Token ledgering in the router.**

  Step 6 asks each iteration for a line shaped like:

  ```text
  **Delegation**: delegated <what> (<tier>)
  ```

  **Next**: the budget guard.

- 2026-07-28 · spec 05-materials-ingestion · PR #48 · **Retry on failed ingestion jobs.**

  The template again, for the record:

  ```text
  **Delegation**: skipped <what> because <reason>
  ```

  **Decisions**: the retry budget is per job, not per queue.
