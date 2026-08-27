-- Create matches on mutual likes and expose a guarded message-send RPC.

create or replace function public.create_match_on_mutual_like()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_liker_profile_id uuid;
  v_target_user_id uuid;
begin
  if new.action <> 'like' then
    return new;
  end if;

  select id
  into v_liker_profile_id
  from public.profiles
  where user_id = new.liker_user_id
  limit 1;

  select user_id
  into v_target_user_id
  from public.profiles
  where id = new.target_profile_id
  limit 1;

  if v_liker_profile_id is null
     or v_target_user_id is null
     or v_target_user_id = new.liker_user_id then
    return new;
  end if;

  if exists (
    select 1
    from public.likes
    where liker_user_id = v_target_user_id
      and target_profile_id = v_liker_profile_id
      and action = 'like'
  ) then
    insert into public.matches (
      user_a_id,
      user_b_id,
      profile_a_id,
      profile_b_id
    )
    select
      least(new.liker_user_id, v_target_user_id),
      greatest(new.liker_user_id, v_target_user_id),
      case when new.liker_user_id < v_target_user_id then v_liker_profile_id else new.target_profile_id end,
      case when new.liker_user_id < v_target_user_id then new.target_profile_id else v_liker_profile_id end
    where not exists (
      select 1
      from public.matches
      where user_a_id = least(new.liker_user_id, v_target_user_id)
        and user_b_id = greatest(new.liker_user_id, v_target_user_id)
    );
  end if;

  return new;
end;
$$;

drop trigger if exists likes_create_match_on_mutual_like on public.likes;
create trigger likes_create_match_on_mutual_like
after insert on public.likes
for each row
execute function public.create_match_on_mutual_like();

create or replace function public.send_match_message(p_match_id uuid, p_body text)
returns public.messages
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_match public.matches%rowtype;
  v_message public.messages%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Authentication required.'
      using errcode = '28000';
  end if;

  if nullif(trim(p_body), '') is null then
    raise exception 'Message body cannot be empty.'
      using errcode = '22023';
  end if;

  select *
  into v_match
  from public.matches
  where id = p_match_id
    and (user_a_id = auth.uid() or user_b_id = auth.uid());

  if not found then
    raise exception 'Match not found or current user is not a participant.'
      using errcode = '42501';
  end if;

  insert into public.messages (match_id, sender_id, body)
  values (p_match_id, auth.uid(), trim(p_body))
  returning * into v_message;

  return v_message;
end;
$$;

grant execute on function public.send_match_message(uuid, text) to authenticated;
