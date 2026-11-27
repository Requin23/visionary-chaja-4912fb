# Security hardening rollout

Apply these changes to the Supabase project before deploying the updated app.

## 1. Apply the database migration

The original hardening migration [`20261127_security_hardening.sql`](20261127_security_hardening.sql) invalidates pending verification codes, removes their plaintext values, installs transactional request/attempt limits, and creates the private profile-report table. If that migration has already been run, do not rerun it; run only the additive [`20261128_moderation_queue.sql`](20261128_moderation_queue.sql) migration for the moderator review metadata.

The migration intentionally invalidates any outstanding email codes. Users can request new codes after the new Edge Functions are deployed.

## 2. Configure and deploy the Edge Functions

Add a private random `VERIFICATION_CODE_PEPPER` secret (at least 32 random bytes) and set `MODERATOR_USER_IDS` to the comma-separated Supabase Auth user IDs of trusted moderators. Keep these values, `SUPABASE_SERVICE_ROLE_KEY`, and `RESEND_API_KEY` in Supabase secrets only; none belongs in browser code. To find a moderator's ID, run `select id, email from auth.users;` in the SQL editor and copy only the intended account ID into the secret.

The updated code is already pushed to the GitHub branch `security/verification-hardening`. To publish the visual and app changes, merge that branch into the branch used by your hosting service. The Edge Functions can be deployed from this checked-out branch. Deploy `send-verification-code` and `verify-code` with JWT verification disabled because signup and email confirmation happen before a user session exists. Deploy `moderation` with JWT verification enabled; it also checks the signed-in user against `MODERATOR_USER_IDS`.

Example deployment commands from the repository folder:

```bash
npx supabase@latest functions deploy send-verification-code --no-verify-jwt --project-ref mmsrozfrrzyyxwpebnxb
npx supabase@latest functions deploy verify-code --no-verify-jwt --project-ref mmsrozfrrzyyxwpebnxb
npx supabase@latest functions deploy moderation --project-ref mmsrozfrrzyyxwpebnxb
```

## 3. Review the live Row Level Security policies

Policy changes made in the Supabase dashboard are not represented in this repository. Run this read-only query in the Supabase SQL editor and review the result before launch:

```sql
select
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  p.policyname,
  p.cmd,
  p.roles,
  p.qual,
  p.with_check
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
left join pg_policies p on p.schemaname = n.nspname and p.tablename = c.relname
where n.nspname = 'public'
  and c.relname in (
    'profiles', 'likes', 'matches', 'messages', 'blocks', 'annonces',
    'profile_reports', 'verification_codes', 'push_subscriptions', 'notifications'
  )
order by c.relname, p.policyname;
```

Confirm that RLS is enabled on every listed table. A signed-in user should only be able to read or change their own private data; messages should be available only to match participants; profile reports and verification codes should not be readable by ordinary users. The app should be able to submit a report only for the signed-in user and a different user's profile.

The policy listing is a review aid, not a proof that every policy is safe. Verify behavior with two ordinary test accounts and an unauthenticated session before opening registration publicly.
