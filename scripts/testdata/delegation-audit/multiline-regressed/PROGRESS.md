# Progress Log

- 2026-07-30 · spec 21-iac-pulumi · PR #50 · **Provisioned the Supabase storage buckets.**

  **Decisions**: the bucket policy is per-course rather than per-user.

  **Next**: slice 2 — the IAM roles.

- 2026-07-29 · spec 06-llm-router-budget · PR #49 · **Token consumption ledgering in the router.**

  **Accepted finding**: the ledger's course attribution is partial; the embed path is not attributed.

  **Next**: the budget guard.

- 2026-07-28 · spec 05-materials-ingestion · PR #48 · **Retry on failed ingestion jobs.**

  **Decisions**: the retry budget is per job, not per queue.

- 2026-07-27 · spec 05-materials-ingestion · PR #47 · **The ingestion worker.**

  **Delegation**: delegated the seed fixtures (`Gemini 3.6 Flash (Medium)`).
