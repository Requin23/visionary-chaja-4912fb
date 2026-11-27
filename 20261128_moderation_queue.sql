-- Add review metadata to the private profile report queue.
alter table public.profile_reports
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null;

create index if not exists profile_reports_status_created_idx
  on public.profile_reports (status, created_at desc);
