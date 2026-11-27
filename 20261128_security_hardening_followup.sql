-- Follow-up security fixes for notifications, private match media and messages.
-- Apply once in the Supabase SQL Editor after the existing app migrations.

-- Authenticated users must not be able to forge notifications for other users.
-- Trigger wrapper functions execute as their owner and can still call this function.
revoke all on function public.enqueue_notification(uuid, text, text, text, uuid, jsonb)
  from public, anon, authenticated;

-- Enforce Google-only new accounts in Auth, including direct API signup calls.
-- Existing email/password users may still sign in; this hook runs only at creation.
create or replace function public.before_user_created_google_only(event jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_provider text;
begin
  v_provider := event #>> '{user,app_metadata,provider}';
  if v_provider is distinct from 'google' then
    return pg_catalog.jsonb_build_object(
      'error', pg_catalog.jsonb_build_object(
        'http_code', 403,
        'message', 'Crée ton compte avec Google.'
      )
    );
  end if;
  return '{}'::jsonb;
end;
$$;

revoke all on function public.before_user_created_google_only(jsonb) from public, anon, authenticated;
grant execute on function public.before_user_created_google_only(jsonb) to supabase_auth_admin;

-- Move the push service credential from a database setting into Supabase Vault.
create extension if not exists supabase_vault with schema vault;

do $$
declare
  v_service_key text;
begin
  select decrypted_secret into v_service_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if nullif(v_service_key, '') is null then
    v_service_key := current_setting('app.settings.service_role_key', true);
    if nullif(v_service_key, '') is not null then
      perform vault.create_secret(
        v_service_key,
        'supabase_service_role_key',
        'Service credential used only by the database push trigger'
      );
    end if;
  end if;
end;
$$;

create or replace function public.call_send_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text;
  v_service_key text;
begin
  if new.pushed_at is not null then
    return new;
  end if;

  v_url := pg_catalog.current_setting('app.settings.supabase_url', true);
  select decrypted_secret into v_service_key
  from vault.decrypted_secrets
  where name = 'supabase_service_role_key'
  limit 1;

  if coalesce(v_url, '') = '' or coalesce(v_service_key, '') = '' then
    return new;
  end if;

  perform net.http_post(
    url := v_url || '/functions/v1/send-push',
    headers := pg_catalog.jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_service_key
    ),
    body := pg_catalog.jsonb_build_object('notification_id', new.id)
  );

  return new;
end;
$$;

-- Keep profile avatars public; only chat media becomes private.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('chat-images', 'chat-images', false, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('chat-audio', 'chat-audio', false, 10485760, array['audio/webm', 'audio/ogg', 'audio/mpeg', 'audio/mp4', 'audio/wav'])
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.can_upload_chat_media(p_owner_id text, p_match_id text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner_id uuid;
  v_match_id uuid;
begin
  if auth.uid() is null
     or p_owner_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or p_match_id !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  v_owner_id := p_owner_id::uuid;
  v_match_id := p_match_id::uuid;

  return auth.uid() = v_owner_id and exists (
    select 1
    from public.matches as m
    where m.id = v_match_id
      and (m.user_a_id = auth.uid() or m.user_b_id = auth.uid())
  );
end;
$$;

create or replace function public.can_read_chat_media(p_bucket_id text, p_object_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_owner_text text;
  v_owner_id uuid;
begin
  if auth.uid() is null or p_bucket_id not in ('chat-images', 'chat-audio') then
    return false;
  end if;

  v_owner_text := pg_catalog.split_part(p_object_name, '/', 1);
  if v_owner_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  v_owner_id := v_owner_text::uuid;

  if v_owner_id = auth.uid() then
    return true;
  end if;

  return exists (
    select 1
    from public.messages as msg
    join public.matches as m on m.id = msg.match_id
    where msg.sender_id = v_owner_id
      and (m.user_a_id = auth.uid() or m.user_b_id = auth.uid())
      and (
        pg_catalog.strpos(msg.body, p_bucket_id || '/' || p_object_name) > 0
        or pg_catalog.strpos(msg.body, '/storage/v1/object/public/' || p_bucket_id || '/' || p_object_name) > 0
      )
  );
end;
$$;

revoke all on function public.can_upload_chat_media(text, text) from public;
revoke all on function public.can_read_chat_media(text, text) from public, anon;
grant execute on function public.can_upload_chat_media(text, text) to anon, authenticated;
grant execute on function public.can_read_chat_media(text, text) to anon, authenticated;

drop policy if exists chat_media_upload_match_participant on storage.objects;
create policy chat_media_upload_match_participant
on storage.objects
for insert
to authenticated
with check (
  bucket_id in ('chat-images', 'chat-audio')
  and name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]+-(photo|voice)\.(jpg|jpeg|png|webp|webm|ogg|mp3|m4a|wav)$'
  and public.can_upload_chat_media(pg_catalog.split_part(name, '/', 1), pg_catalog.split_part(name, '/', 2))
);

drop policy if exists chat_media_read_match_participant on storage.objects;
create policy chat_media_read_match_participant
on storage.objects
for select
to authenticated
using (
  bucket_id in ('chat-images', 'chat-audio')
  and public.can_read_chat_media(bucket_id, name)
);

-- Restrictive guards also override any permissive legacy Storage policies.
drop policy if exists chat_media_restrict_select on storage.objects;
create policy chat_media_restrict_select
on storage.objects as restrictive
for select to public
using (
  bucket_id not in ('chat-images', 'chat-audio')
  or public.can_read_chat_media(bucket_id, name)
);

drop policy if exists chat_media_restrict_insert on storage.objects;
create policy chat_media_restrict_insert
on storage.objects as restrictive
for insert to public
with check (
  bucket_id not in ('chat-images', 'chat-audio')
  or (
    name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]+-(photo|voice)\.(jpg|jpeg|png|webp|webm|ogg|mp3|m4a|wav)$'
    and public.can_upload_chat_media(pg_catalog.split_part(name, '/', 1), pg_catalog.split_part(name, '/', 2))
  )
);

drop policy if exists chat_media_restrict_update on storage.objects;
create policy chat_media_restrict_update
on storage.objects as restrictive
for update to public
using (
  bucket_id not in ('chat-images', 'chat-audio')
  or (
    name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]+-(photo|voice)\.(jpg|jpeg|png|webp|webm|ogg|mp3|m4a|wav)$'
    and public.can_upload_chat_media(pg_catalog.split_part(name, '/', 1), pg_catalog.split_part(name, '/', 2))
  )
)
with check (
  bucket_id not in ('chat-images', 'chat-audio')
  or (
    name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]+-(photo|voice)\.(jpg|jpeg|png|webp|webm|ogg|mp3|m4a|wav)$'
    and public.can_upload_chat_media(pg_catalog.split_part(name, '/', 1), pg_catalog.split_part(name, '/', 2))
  )
);

drop policy if exists chat_media_restrict_delete on storage.objects;
create policy chat_media_restrict_delete
on storage.objects as restrictive
for delete to public
using (
  bucket_id not in ('chat-images', 'chat-audio')
  or (
    name ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]+-(photo|voice)\.(jpg|jpeg|png|webp|mp3|m4a|wav|webm|ogg)$'
    and public.can_upload_chat_media(pg_catalog.split_part(name, '/', 1), pg_catalog.split_part(name, '/', 2))
  )
);

-- Enforce a server-side size limit even for direct PostgREST/RPC callers.
create or replace function public.enforce_message_body_size()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.body is null or pg_catalog.char_length(new.body) > 5000 then
    raise exception 'Message is too long.' using errcode = '22001';
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_message_body_size() from public, anon, authenticated;
drop trigger if exists messages_body_size_limit on public.messages;
create trigger messages_body_size_limit
before insert or update of body on public.messages
for each row execute function public.enforce_message_body_size();

-- Do not place private message text on lock screens or in remote push previews.
create or replace function public.notify_message_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_a uuid;
  v_user_b uuid;
  v_target_user uuid;
begin
  select user_a_id, user_b_id into v_user_a, v_user_b
  from public.matches
  where id = new.match_id;

  if new.sender_id = v_user_a then
    v_target_user := v_user_b;
  elsif new.sender_id = v_user_b then
    v_target_user := v_user_a;
  else
    return new;
  end if;

  if v_target_user is not null and v_target_user <> new.sender_id then
    perform public.enqueue_notification(
      v_target_user,
      'message',
      'mbifê',
      'Tu as reçu un nouveau message.',
      new.id,
      pg_catalog.jsonb_build_object('match_id', new.match_id, 'message_id', new.id)
    );
  end if;
  return new;
end;
$$;

revoke all on function public.notify_message_insert() from public, anon, authenticated;

-- If the service-role key was previously stored in this database setting,
-- run these two statements separately after this migration succeeds:
-- alter database postgres reset app.settings.service_role_key;
-- select pg_reload_conf();
-- Also enable Authentication > Hooks > Before User Created and select
-- public.before_user_created_google_only(jsonb) to enforce Google-only signup.
-- After making the chat buckets private, purge their Storage CDN cache in the
-- Supabase Dashboard so previously cached public object URLs are invalidated.
