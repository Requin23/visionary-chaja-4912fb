-- Repair for projects where push triggers were already installed with profiles.name.
-- Run this in Supabase SQL Editor if likes/messages fail with: column "name" does not exist.

create or replace function public.notify_like_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target_user uuid;
  v_liker_name text;
  v_kind text;
begin
  select user_id into v_target_user from public.profiles where id = new.target_profile_id;
  select coalesce(display_name, 'Quelqu''un') into v_liker_name from public.profiles where user_id = new.liker_user_id limit 1;
  v_kind := case when coalesce(new.action, '') = 'spark' then 'spark' else 'like' end;

  if v_target_user is not null and v_target_user <> new.liker_user_id then
    perform public.enqueue_notification(
      v_target_user,
      v_kind,
      case when v_kind = 'spark' then 'Nouveau spark' else 'Nouveau like' end,
      v_liker_name || case when v_kind = 'spark' then ' t''a envoye un spark.' else ' aime ton profil.' end,
      new.id,
      jsonb_build_object('like_id', new.id, 'profile_id', new.target_profile_id)
    );
  end if;

  return new;
end;
$$;

create or replace function public.notify_message_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_a uuid;
  v_user_b uuid;
  v_target_user uuid;
  v_sender_name text;
begin
  select user_a_id, user_b_id into v_user_a, v_user_b from public.matches where id = new.match_id;
  v_target_user := case when new.sender_id = v_user_a then v_user_b else v_user_a end;
  select coalesce(display_name, 'Nouveau message') into v_sender_name from public.profiles where user_id = new.sender_id limit 1;

  if v_target_user is not null and v_target_user <> new.sender_id then
    perform public.enqueue_notification(
      v_target_user,
      'message',
      v_sender_name,
      left(coalesce(new.body, 'Tu as un nouveau message.'), 160),
      new.id,
      jsonb_build_object('match_id', new.match_id, 'message_id', new.id)
    );
  end if;

  return new;
end;
$$;
