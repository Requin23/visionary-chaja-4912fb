-- Server-side rate limit for messages.
-- Allows at most one message every 3 seconds per sender_id.

create or replace function public.enforce_messages_sender_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_last_created_at timestamptz;
begin
  select created_at
  into v_last_created_at
  from public.messages
  where sender_id = new.sender_id
  order by created_at desc
  limit 1;

  if v_last_created_at is not null
     and v_last_created_at > now() - interval '3 seconds' then
    raise exception 'Rate limit exceeded: wait at least 3 seconds between messages.'
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists messages_sender_rate_limit on public.messages;
create trigger messages_sender_rate_limit
before insert on public.messages
for each row
execute function public.enforce_messages_sender_rate_limit();
