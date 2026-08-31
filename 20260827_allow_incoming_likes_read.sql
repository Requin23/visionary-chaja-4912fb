-- Allow users to read likes/sparks sent to their own profile.

drop policy if exists "Users read incoming likes" on public.likes;
create policy "Users read incoming likes"
on public.likes
for select
to authenticated
using (
  auth.uid() = liker_user_id
  or exists (
    select 1
    from public.profiles
    where profiles.id = likes.target_profile_id
      and profiles.user_id = auth.uid()
  )
);
