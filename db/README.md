# Database artifacts

`local_cache_v1.sql` is an executable reference LOCAL SQLite schema for testing persistence shapes and constraints. It is not the production database layer and not a Supabase migration. It requires the repository implementation to capture/save drawing+outbox in one transaction and to verify actual files before setting ready. A check constraint cannot validate a PDF checksum or enforce who physically owns the iPad.

The full production relational model, RPC algorithms, authorization rules, and migration gates are in `docs/06_DATA_AND_API.md` and `docs/10_SECURITY_AND_RIGHTS.md`. Codex must implement real Supabase migrations, policies, Storage rules, and function tests. No server schema in this handoff is labeled ready to deploy.

Local account partitions must be selected using authenticated identity, never a user-editable tenant string. Apply immutable chart/page metadata rules in the repository adapter. The reference SQL is an initial schema, not an upgrade script for an existing database; use GRDB migrations in the application rather than executing it twice or resetting user data.
