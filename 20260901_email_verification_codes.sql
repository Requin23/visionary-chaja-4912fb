create table if not exists public.verification_codes (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  code text not null check (char_length(code) = 6),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  verified boolean not null default false
);

alter table public.verification_codes enable row level security;

create index if not exists verification_codes_email_created_idx
on public.verification_codes (lower(email), created_at desc);
