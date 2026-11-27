-- Only a verified Supabase Auth email or phone may produce a verified profile.
-- The service role remains the only trusted exception for the verification Edge Function.

create or replace function public.sync_profile_verification_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  auth_verified boolean;
begin
  if auth.role() = 'service_role' then
    return new;
  end if;

  select (u.email_confirmed_at is not null or u.phone_confirmed_at is not null)
    into auth_verified
  from auth.users as u
  where u.id = new.user_id;

  new.is_verified := coalesce(auth_verified, false);
  return new;
end;
$$;

revoke all on function public.sync_profile_verification_status() from public, anon, authenticated;

drop trigger if exists profiles_sync_verification_status on public.profiles;
create trigger profiles_sync_verification_status
before insert or update of user_id, is_verified on public.profiles
for each row
execute function public.sync_profile_verification_status();

-- Remove badges previously granted by client-side profile saves.
update public.profiles as p
set is_verified = (u.email_confirmed_at is not null or u.phone_confirmed_at is not null)
from auth.users as u
where u.id = p.user_id
  and p.is_verified is distinct from (u.email_confirmed_at is not null or u.phone_confirmed_at is not null);
