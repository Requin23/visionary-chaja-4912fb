alter table public.profiles
alter column is_active set default true;

update public.profiles
set is_active = true
where is_active is distinct from true;
