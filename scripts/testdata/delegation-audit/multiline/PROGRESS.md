# Progress Log

- 2026-07-30 · spec 21-iac-pulumi · PR #50 · **Provisioned the Supabase storage buckets.** Cut fresh off `origin/main`; the slice plan was judged first and adopted unchanged.

  **Decisions**: the bucket policy is per-course rather than per-user, because a course is the unit anyone shares.

  **Delegation**: delegated the Pulumi stack export script (`Gemini 3.6 Flash (Medium)`), verified on disk before use.

  **Next**: slice 2 — the IAM roles.

- 2026-07-29 · spec 06-llm-router-budget · PR #49 · **Token consumption ledgering in the router.** Gates ran as fresh headless sessions.

  **Delegation**: delegated the OpenAPI client regeneration (`Gemini 3.6 Flash (Medium)`).

  **Next**: the budget guard.

- 2026-07-28 · spec 05-materials-ingestion · PR #48 · **Retry on failed ingestion jobs.**

  **Delegation**: skipped the fixture generation because every fixture here is an assertion, not seed data.
