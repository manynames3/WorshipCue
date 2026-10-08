# Official sources and how they inform this specification
Reviewed 2026-10-07. Product choices, numeric qualification targets, pricing hypotheses, and the team's workflow are design decisions, not claims from these sources. Recheck current documentation and policy at implementation/release. No claim is made that APIs were exercised merely because documentation was read.

- **S01 · Apple, What's new in PDFKit (WWDC22).** PDF page-overlay integration, including a PencilKit canvas example. https://developer.apple.com/videos/play/wwdc2022/10089/
- **S02 · Apple, PencilKit / PKDrawing.** Native drawing representation and serialization. https://developer.apple.com/documentation/pencilkit/pkdrawing-swift.struct
- **S03 · Supabase Swift client introduction.** Official native SDK entry point. https://supabase.com/docs/reference/swift/introduction
- **S04 · Supabase Row Level Security.** Database access-policy mechanisms. https://supabase.com/docs/guides/database/postgres/row-level-security
- **S05 · Supabase Storage access control / buckets.** Private asset authorization via policies. https://supabase.com/docs/guides/storage/security/access-control and https://supabase.com/docs/guides/storage/buckets/fundamentals
- **S06 · Supabase Realtime documentation.** Postgres Changes/Broadcast/Presence capabilities. https://supabase.com/docs/guides/realtime
- **S07 · Supabase, Realtime or Pipelines? (2026-05-05).** Explicitly notes that Postgres Changes does not guarantee delivery or replay after client disconnection. This drives authoritative snapshots and reconciliation. https://supabase.com/blog/realtime-or-pipelines-how-to-choose-the-right-tool
- **S08 · Supabase Anonymous Sign-Ins.** Anonymous users are authenticated identities, so anonymous status/grants require explicit access distinctions. https://supabase.com/docs/guides/auth/auth-anonymous
- **S09 · Supabase passwordless email sign-in.** Managed email OTP setup and validation. https://supabase.com/docs/guides/auth/auth-email-passwordless
- **S10 · GRDB project README.** SQLite toolkit and concurrency/migration facilities; verify pinned version/license on adoption. https://github.com/groue/GRDB.swift/blob/master/README.md
- **S11 · CCLI US Church Copyright License.** Illustrates licensed permissions and the need to check scope rather than assume all sheet-music uses are allowed. https://ccli.com/us/en/church-copyright-license
- **S12 · CCLI Korean Church Copyright License Summary.** Territory-specific summary; page surfaced in search but full direct retrieval failed during preparation. Treat as a reference to verify directly, NOT as a complete legal clearance. https://ccli.com/kr/en/church-copyright-license-summary
- **S13 · Apple App Review Guidelines.** Relevant areas include completeness/testing, user-generated content, privacy/account deletion, beta distribution, and purchase rules. Specific payment treatment requires current review; no automatic enterprise exception assumed. https://developer.apple.com/app-store/review/guidelines/
- **S14 · OpenAI Codex AGENTS.md documentation.** Repository-level instructions. https://developers.openai.com/codex/agent-configuration/agents-md
- **S15 · OpenAI Codex best practices.** Context, execution, and validation workflow. https://developers.openai.com/codex/learn/best-practices

## Alternatives considered
Cloudflare Durable Objects support state coordination and persistent storage, but adding custom authentication, D1/R2 coordination, and a dedicated live-session tier is not needed for the chosen pilot behavior. This is a simplicity judgment, not a claim that Cloudflare is unsuitable. Official reference: https://developers.cloudflare.com/durable-objects/

## Known research limits
No interviews beyond the user's supplied workflow, no actual church budget approval, no hardware tests, no App Review decision, and no live infrastructure benchmarking were performed in preparing this package. Earlier competitor/market claims from the conversation are not used as validated requirements.
