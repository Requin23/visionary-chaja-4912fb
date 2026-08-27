-- Prevent duplicate relationship rows at the database level.

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'likes_liker_target_unique'
      and conrelid = 'public.likes'::regclass
  ) then
    alter table public.likes
      add constraint likes_liker_target_unique unique (liker_user_id, target_profile_id);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'matches_user_pair_unique'
      and conrelid = 'public.matches'::regclass
  ) then
    alter table public.matches
      add constraint matches_user_pair_unique unique (user_a_id, user_b_id);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'blocks_blocker_blocked_unique'
      and conrelid = 'public.blocks'::regclass
  ) then
    alter table public.blocks
      add constraint blocks_blocker_blocked_unique unique (blocker_user_id, blocked_user_id);
  end if;
end $$;
