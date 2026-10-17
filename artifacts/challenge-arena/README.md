# Challenge Arena

A mobile-first challenge platform for college friend groups. Members create safe group challenges, submit completions, review each other, earn points after approval, and compare weekly or all-time group standings.

## Stack and trust boundaries

- React, TypeScript, Vite, Tailwind CSS, and Wouter
- Supabase Auth for account creation, sign-in, session persistence, and password recovery
- Supabase PostgreSQL with RLS for every Challenge Arena table
- Express API forwards the signed-in user's Supabase access token and uses only the public anon key. It never uses a service-role key.
- Private Supabase Storage bucket for optional evidence images
- Database functions validate group/challenge operations, review submissions under row locks, and create an immutable points-ledger entry in the same transaction as approval

## Configure Supabase

1. Create a Supabase project and enable Email sign-in under **Authentication → Providers**. If email confirmation is enabled, complete the confirmation link before signing in.
2. Add the project URL and public anon key as Replit environment variables:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
   These are the only Supabase values the running app needs. The public anon key is intended for browser use; RLS is the security boundary. **Never put a service-role key in a `VITE_` variable or in client code.**
3. Apply `supabase/migrations/202610170001_challenge_arena.sql` to the same Supabase project, then apply `supabase/seed.sql`.
   - With the Supabase CLI: from `artifacts/challenge-arena`, link the project and run `supabase db push`, then apply `supabase/seed.sql` with the CLI or SQL editor.
   - Or paste the migration, then the seed script, into the Supabase SQL editor.
4. Set the Supabase Auth **Site URL** to the published app origin and add the app origin plus `/auth/recover` to the allowed redirect URLs.
5. Start the workspace workflows. The API server and frontend both read the shared Supabase URL and anon key.

The migration creates the private `challenge-evidence` bucket and policies. Evidence is stored under `{user_id}/{challenge_id}/{filename}`. Only its owner, the challenge creator, or the group owner can read it. Physical challenge photos are never treated as definitive proof; every submission remains subject to human review.

## Environment example

See `.env.example` for placeholder values. Do not commit actual project keys, database passwords, service-role keys, or user credentials.

## Database map

- `profiles`: auth-linked username, display name, optional avatar; scores are deliberately not editable profile columns.
- `groups` and `memberships`: private groups and owner/member roles; a unique constraint prevents duplicate membership.
- `invitations`: one-time-visible random invitation codes; only a SHA-256 hash is stored, with expiry and use limits.
- `challenge_templates`: the 20 original safe starter challenges loaded by the controlled seed.
- `challenges` and `assignments`: group challenge definitions, retry limits, participant assignment, and workflow state.
- `submissions` and `review_history`: each attempt and its authorized decision history.
- `points_ledger`: append-only approved awards, unique by submission. Totals and rankings are derived from this ledger.
- `reports`: persisted user reports; reporters and relevant group owners have restricted read access.

Indexes cover usernames, memberships, challenge group/deadline searches, assignment status, review queues, reports, and chronological ledger queries. Foreign keys use cascading deletes for membership/challenge-owned records and restrictive deletes for award history and group ownership.

## Important rules

- Owners create invitations and manage members. Challenge creators and group owners can review, but never their own submission.
- Every completion award uses the server-stored challenge points, and a unique ledger constraint prevents a second reward for the same submission.
- Weekly scoring starts Monday at 00:00 in `Asia/Kolkata`. All-time scores remain in the ledger.
- Rejected submissions may be retried up to the challenge's configured attempt limit. Expired and cancelled assignments cannot be submitted.
- The server rejects common unsafe challenge patterns; that filter is intentionally conservative and not a substitute for group-owner review or reporting.
- No public global feed, AI-generated challenges, chat, paid points, or cash prizes are included.

## Development and verification

```sh
pnpm install
pnpm --filter @workspace/api-spec run codegen
pnpm --filter @workspace/api-server run typecheck
pnpm --filter @workspace/challenge-arena run typecheck
```

To verify multiple-account behavior, use two separate test accounts in the same Supabase project and follow this checklist:

1. Sign up, confirm email if required, sign in, refresh, request a password reset, and sign out.
2. Create a private group with account A; create an invitation; join from account B in a separate browser session.
3. Confirm a non-member cannot read the group or its challenges. Create a group challenge assigned to B.
4. Submit as B; approve as A; verify points change exactly once after refresh and repeated approval is rejected.
5. Reject another submission and verify retry eligibility follows `max_attempts`.
6. Compare the group's weekly and all-time leaderboards. A user's score and ledger remain unchanged when profile data is edited.
7. Upload evidence as B and confirm only B, the creator, and the group owner can read it.
8. Submit a report as B; confirm it is visible to its reporter and relevant owner, and unavailable to unrelated users.

The workspace automated checks validate generated API contracts and TypeScript compilation. Authenticated database flows require the migration to be applied to the configured Supabase project and independent test accounts; do not treat an unrun checklist step as passed.

## Known limits

- A Supabase project and the migration/seed scripts must be configured before real app data can load. No database or account data is fabricated as a fallback.
- The included server-side unsafe-content checks cover common prohibited patterns but cannot determine context or guarantee moderation. Group owners should review challenge content and act on reports.
- Evidence supports review context only; it does not establish that a physical task was performed.
- The application has no administrative organization-wide moderation role; reports are routed to relevant group owners.
