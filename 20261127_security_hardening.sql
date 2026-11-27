-- Security hardening for email verification and profile reports.
-- Apply in the Supabase SQL editor before deploying the updated Edge Functions.

-- Invalidate existing codes and remove the plaintext column. Users can request
-- a fresh code after deployment.
alter table public.verification_codes
  add column if not exists code_hash text,
  add column if not exists attempt_count integer not null default 0;

update public.verification_codes
set verified = true,
    code_hash = coalesce(code_hash, 'invalidated');

alter table public.verification_codes
  alter column code_hash set not null;

alter table public.verification_codes
  drop column if exists code;

create table if not exists public.verification_code_rate_limits (
  email text primary key,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 0,
  last_requested_at timestamptz not null default now()
);

alter table public.verification_code_rate_limits enable row level security;
revoke all on public.verification_code_rate_limits from anon, authenticated;
grant all on public.verification_code_rate_limits to service_role;

create or replace function public.reserve_verification_code_request(p_email text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(p_email));
  v_limit public.verification_code_rate_limits%rowtype;
begin
  if v_email = '' or length(v_email) > 254 then
    return false;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_email, 0));

  insert into public.verification_code_rate_limits(email)
  values (v_email)
  on conflict (email) do nothing;

  select * into v_limit
  from public.verification_code_rate_limits
  where email = v_email
  for update;

  if v_limit.last_requested_at > now() - interval '60 seconds' then
    return false;
  end if;

  if v_limit.window_started_at <= now() - interval '1 hour' then
    update public.verification_code_rate_limits
    set window_started_at = now(), request_count = 1, last_requested_at = now()
    where email = v_email;
    return true;
  end if;

  if v_limit.request_count >= 5 then
    return false;
  end if;

  update public.verification_code_rate_limits
  set request_count = request_count + 1, last_requested_at = now()
  where email = v_email;
  return true;
end;
$$;

revoke all on function public.reserve_verification_code_request(text) from public, anon, authenticated;
grant execute on function public.reserve_verification_code_request(text) to service_role;

create or replace function public.verify_email_code(p_email text, p_code_hash text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code public.verification_codes%rowtype;
begin
  select * into v_code
  from public.verification_codes
  where email = lower(trim(p_email)) and verified = false
  order by created_at desc
  limit 1
  for update;

  if not found then
    return 'expired';
  end if;

  if v_code.expires_at <= now() then
    update public.verification_codes set verified = true where id = v_code.id;
    return 'expired';
  end if;

  if v_code.attempt_count >= 5 then
    update public.verification_codes set verified = true where id = v_code.id;
    return 'locked';
  end if;

  if v_code.code_hash <> p_code_hash then
    update public.verification_codes
    set attempt_count = attempt_count + 1,
        verified = (attempt_count + 1 >= 5)
    where id = v_code.id;
    return case when v_code.attempt_count + 1 >= 5 then 'locked' else 'invalid' end;
  end if;

  update public.verification_codes set verified = true where id = v_code.id;
  return 'verified';
end;
$$;

revoke all on function public.verify_email_code(text, text) from public, anon, authenticated;
grant execute on function public.verify_email_code(text, text) to service_role;

-- The app already submits profile reports to this table. Keep reports private
-- to the backend and allow a signed-in person to submit only their own report.
create table if not exists public.profile_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_user_id uuid not null references auth.users(id) on delete cascade,
  target_profile_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (char_length(trim(reason)) between 5 and 1000),
  status text not null default 'new' check (status in ('new', 'reviewing', 'actioned', 'dismissed')),
  created_at timestamptz not null default now()
);

alter table public.profile_reports enable row level security;
revoke all on public.profile_reports from anon;
grant insert on public.profile_reports to authenticated;
grant all on public.profile_reports to service_role;

create or replace function public.can_report_profile(p_profile_id uuid, p_reporter_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_reporter_id = auth.uid() and exists (
    select 1 from public.profiles p
    where p.id = p_profile_id and p.user_id <> p_reporter_id
  );
$$;

revoke all on function public.can_report_profile(uuid, uuid) from public, anon;
grant execute on function public.can_report_profile(uuid, uuid) to authenticated;

drop policy if exists profile_reports_submit_own on public.profile_reports;
create policy profile_reports_submit_own
on public.profile_reports
for insert
to authenticated
with check (
  reporter_user_id = auth.uid()
  and public.can_report_profile(target_profile_id, auth.uid())
);

create index if not exists profile_reports_created_at_idx
  on public.profile_reports (created_at desc);
create index if not exists profile_reports_target_created_idx
  on public.profile_reports (target_profile_id, created_at desc);

create or replace function public.limit_profile_report_rate()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  perform pg_advisory_xact_lock(hashtextextended(new.reporter_user_id::text, 1));
  select count(*) into v_count
  from public.profile_reports
  where reporter_user_id = new.reporter_user_id
    and created_at > now() - interval '24 hours';
  if v_count >= 10 then
    raise exception 'Report limit reached. Try again later.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists profile_reports_rate_limit on public.profile_reports;
create trigger profile_reports_rate_limit
before insert on public.profile_reports
for each row execute function public.limit_profile_report_rate();

revoke all on function public.limit_profile_report_rate() from public, anon, authenticated;

