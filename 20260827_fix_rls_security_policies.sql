-- Fix RLS security gaps for messages, annonces, push_subscriptions, blocks, and profiles.
-- Run this once in the Supabase SQL Editor.

drop policy if exists "messages_members" on public.messages;

drop policy if exists "annonces_insert_auth" on public.annonces;
create policy "annonces_insert_auth"
on public.annonces
for insert
to authenticated
with check (
  author_id = auth.uid()
  or (anonymous = true and author_id is null)
);

drop policy if exists "service select all" on public.push_subscriptions;

alter table public.blocks enable row level security;

drop policy if exists "blocks_owner_all" on public.blocks;
create policy "blocks_owner_all"
on public.blocks
for all
to authenticated
using (auth.uid() = blocker_user_id)
with check (auth.uid() = blocker_user_id);

drop table if exists public.blocked_users;

drop policy if exists "profiles_public_read" on public.profiles;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'age_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint age_check check (age >= 18);
  end if;
end $$;
