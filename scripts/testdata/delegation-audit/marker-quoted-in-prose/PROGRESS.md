# Progress Log

- 2026-07-30 · spec 21-iac-pulumi · PR #50 · **Provisioned the Supabase storage buckets.**

  **Tooling defect found, not fixed here**: `scripts/delegation-audit.sh` reports 0/3 even though
  four live entries carry a verbatim `**Delegation**:` marker. Its parser tests marker-presence on
  the entry's header line, where no iteration has ever put the note.

- 2026-07-29 · spec 06-llm-router-budget · PR #49 · **Token consumption ledgering in the router.**

  **Decisions**: the ledger writes one row per call. Step 6's `**Delegation**:` note is what the
  audit greps for, and this paragraph is describing that rule rather than following it.

- 2026-07-28 · spec 05-materials-ingestion · PR #48 · **Retry on failed ingestion jobs.**

  **Next**: the digest. It should carry a **Delegation**: line, which this iteration did not write.
