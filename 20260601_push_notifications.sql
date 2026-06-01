-- Push notifications for mbife.
-- Run this in Supabase SQL Editor, then deploy supabase/functions/send-push.

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, endpoint)
);

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('message', 'like', 'spark', 'match', 'system')),
  title text not null default 'mbife',
  body text not null default 'Tu as une nouvelle activite.',
  source_id uuid,
  data jsonb not null default '{}'::jsonb,
  pushed_at timestamptz,
  created_at timestamptz not null default now()
);

alter table public.push_subscriptions enable row level security;
alter table public.notifications enable row level security;

drop policy if exists "Users manage own push subscriptions" on public.push_subscriptions;
create policy "Users manage own push subscriptions"
on public.push_subscriptions
for all
to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

drop policy if exists "Users read own notifications" on public.notifications;
create policy "Users read own notifications"
on public.notifications
for select
to authenticated
using (auth.uid() = user_id);

drop policy if exists "Users can delete own notifications" on public.notifications;
create policy "Users can delete own notifications"
on public.notifications
for delete
to authenticated
using (auth.uid() = user_id);

create index if not exists push_subscriptions_user_id_idx on public.push_subscriptions(user_id);
create index if not exists notifications_user_id_created_at_idx on public.notifications(user_id, created_at desc);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists push_subscriptions_set_updated_at on public.push_subscriptions;
create trigger push_subscriptions_set_updated_at
before update on public.push_subscriptions
for each row execute function public.set_updated_at();

create or replace function public.enqueue_notification(
  p_user_id uuid,
  p_kind text,
  p_title text,
  p_body text,
  p_source_id uuid default null,
  p_data jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_user_id is null then
    return null;
  end if;

  insert into public.notifications(user_id, kind, title, body, source_id, data)
  values (
    p_user_id,
    coalesce(nullif(p_kind, ''), 'system'),
    coalesce(nullif(p_title, ''), 'mbife'),
    coalesce(nullif(p_body, ''), 'Tu as une nouvelle activite.'),
    p_source_id,
    coalesce(p_data, '{}'::jsonb)
  )
  returning id into v_id;

  return v_id;
end;
$$;

grant execute on function public.enqueue_notification(uuid, text, text, text, uuid, jsonb) to authenticated;

create extension if not exists pg_net with schema extensions;

create or replace function public.call_send_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_service_key text;
begin
  if new.pushed_at is not null then
    return new;
  end if;

  v_url := current_setting('app.settings.supabase_url', true);
  v_service_key := current_setting('app.settings.service_role_key', true);

  if coalesce(v_url, '') = '' or coalesce(v_service_key, '') = '' then
    return new;
  end if;

  perform extensions.net.http_post(
    url := v_url || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_key
    ),
    body := jsonb_build_object('notification_id', new.id)
  );

  return new;
end;
$$;

drop trigger if exists notifications_send_push on public.notifications;
create trigger notifications_send_push
after insert on public.notifications
for each row execute function public.call_send_push();

-- Optional app triggers. They are installed only when the tables exist.
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

create or replace function public.notify_match_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.enqueue_notification(
    new.user_a_id,
    'match',
    'Nouveau match',
    'Vous pouvez maintenant discuter.',
    new.id,
    jsonb_build_object('match_id', new.id)
  );
  perform public.enqueue_notification(
    new.user_b_id,
    'match',
    'Nouveau match',
    'Vous pouvez maintenant discuter.',
    new.id,
    jsonb_build_object('match_id', new.id)
  );
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

do $$
begin
  if to_regclass('public.likes') is not null then
    drop trigger if exists likes_notify_insert on public.likes;
    create trigger likes_notify_insert
    after insert on public.likes
    for each row execute function public.notify_like_insert();
  end if;

  if to_regclass('public.matches') is not null then
    drop trigger if exists matches_notify_insert on public.matches;
    create trigger matches_notify_insert
    after insert on public.matches
    for each row execute function public.notify_match_insert();
  end if;

  if to_regclass('public.messages') is not null then
    drop trigger if exists messages_notify_insert on public.messages;
    create trigger messages_notify_insert
    after insert on public.messages
    for each row execute function public.notify_message_insert();
  end if;
end $$;

-- Required once, in SQL Editor, with your real project URL and service role key:
-- alter database postgres set app.settings.supabase_url = 'https://YOUR_PROJECT.supabase.co';
-- alter database postgres set app.settings.service_role_key = 'YOUR_SERVICE_ROLE_KEY';
-- select pg_reload_conf();
