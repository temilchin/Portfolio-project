-- =============================================================================
-- Anonymous feature — Supabase / Postgres schema
-- Run this in: Supabase Dashboard -> SQL Editor -> New query -> Run.
-- Safe to re-run (idempotent).
-- =============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- Table
-- ----------------------------------------------------------------------------
create table if not exists public.submissions (
  id               uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  category         text not null check (category in ('love','regret','funny','hate','other')),
  message          text not null check (char_length(message) between 1 and 500),
  hint             text not null check (char_length(hint) between 1 and 200),
  reveal_code      text not null unique,
  status           text not null default 'pending' check (status in ('pending','approved','rejected')),
  guess            text,
  guessed_at       timestamptz,
  approved_at      timestamptz,
  writer_confirmed boolean,        -- v2: writer says whether my guess was right (null = not answered)
  confirmed_at     timestamptz,
  ip_hash          text            -- one-way hash, abuse control only, never exposed
);

create index if not exists submissions_status_idx    on public.submissions (status, approved_at desc);
create index if not exists submissions_code_idx      on public.submissions (reveal_code);
create index if not exists submissions_iphash_idx    on public.submissions (ip_hash, created_at desc);

-- ----------------------------------------------------------------------------
-- Row Level Security
--   * anon (the public): NO direct table access. Reads go through the `wall`
--     view; writes go through the Edge Function (service_role, bypasses RLS).
--   * authenticated (you, logged in on admin.html): full access.
-- ----------------------------------------------------------------------------
alter table public.submissions enable row level security;

drop policy if exists "admin full access" on public.submissions;
create policy "admin full access" on public.submissions
  for all to authenticated using (true) with check (true);

-- ----------------------------------------------------------------------------
-- Public wall view: only approved rows, only safe columns.
-- security_invoker = off (definer) so it can read past RLS for anon callers,
-- while still hiding reveal_code and ip_hash.
-- ----------------------------------------------------------------------------
drop view if exists public.wall;
create view public.wall with (security_invoker = off) as
  select id, created_at, category, message, hint,
         guess, guessed_at, approved_at, writer_confirmed
    from public.submissions
   where status = 'approved'
   order by approved_at desc nulls last, created_at desc;

grant select on public.wall to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Reveal lookup by code (one row at a time). SECURITY DEFINER so the writer can
-- look up their own status without being able to read/dump the table.
-- ----------------------------------------------------------------------------
drop function if exists public.reveal_status(text);
create or replace function public.reveal_status(p_code text)
returns table (
  status           text,
  category         text,
  guess            text,
  guessed          boolean,
  guessed_at       timestamptz,
  writer_confirmed boolean
)
language sql
security definer
set search_path = public
as $$
  select s.status,
         s.category,
         s.guess,
         (s.guess is not null) as guessed,
         s.guessed_at,
         s.writer_confirmed
    from public.submissions s
   where s.reveal_code = p_code
   limit 1;
$$;

revoke all on function public.reveal_status(text) from public;
grant execute on function public.reveal_status(text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- v2: writer confirms whether my guess was correct. Single answer only
-- (can't change it once set). Requires a guess to exist.
-- ----------------------------------------------------------------------------
drop function if exists public.confirm_guess(text, boolean);
create or replace function public.confirm_guess(p_code text, p_correct boolean)
returns table (ok boolean, writer_confirmed boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.submissions%rowtype;
begin
  select * into r from public.submissions where reveal_code = p_code limit 1;
  if not found or r.guess is null or r.writer_confirmed is not null then
    return query select false, r.writer_confirmed;
    return;
  end if;
  update public.submissions
     set writer_confirmed = p_correct, confirmed_at = now()
   where reveal_code = p_code;
  return query select true, p_correct;
end;
$$;

revoke all on function public.confirm_guess(text, boolean) from public;
grant execute on function public.confirm_guess(text, boolean) to anon, authenticated;
