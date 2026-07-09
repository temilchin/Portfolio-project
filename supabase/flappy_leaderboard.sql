-- =============================================================================
-- Forest Flappy 3D — leaderboard (unique names + device claim + best-only update)
--
-- Rules:
--   1. Each player_name is UNIQUE (case-insensitive).
--   2. First save CLAIMS the name for that browser's client_id.
--   3. Same device + same name → UPDATE only if the new score is HIGHER.
--   4. Different device trying a claimed name → rejected (name_taken).
--
-- Run in: Supabase Dashboard → SQL Editor → paste ALL of this → Run.
-- Safe to re-run (idempotent).
-- =============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- Table
-- ----------------------------------------------------------------------------
create table if not exists public.flappy_scores (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  player_name  text not null
                 check (char_length(btrim(player_name)) between 1 and 24),
  score        integer not null
                 check (score >= 0 and score <= 100000),
  client_id    text not null
                 check (char_length(client_id) between 4 and 80)
);

-- Add columns if an older version of the table already exists
alter table public.flappy_scores
  add column if not exists updated_at timestamptz not null default now();

-- Older rows may have null client_id — assign a placeholder before enforcing NOT NULL
update public.flappy_scores
   set client_id = 'legacy_' || left(id::text, 8)
 where client_id is null or btrim(client_id) = '';

alter table public.flappy_scores
  alter column client_id set not null;

-- ----------------------------------------------------------------------------
-- Dedupe existing messy rows: keep ONE row per name (best score, then earliest)
-- ----------------------------------------------------------------------------
delete from public.flappy_scores a
 using public.flappy_scores b
 where lower(btrim(a.player_name)) = lower(btrim(b.player_name))
   and a.id <> b.id
   and (
     a.score < b.score
     or (a.score = b.score and a.created_at > b.created_at)
     or (a.score = b.score and a.created_at = b.created_at and a.id::text > b.id::text)
   );

-- Case-insensitive unique name (one pilot name on the whole board)
create unique index if not exists flappy_scores_name_unique_idx
  on public.flappy_scores (lower(btrim(player_name)));

create index if not exists flappy_scores_rank_idx
  on public.flappy_scores (score desc, updated_at asc);

create index if not exists flappy_scores_client_idx
  on public.flappy_scores (client_id);

-- ----------------------------------------------------------------------------
-- RLS: public can READ; writes go through SECURITY DEFINER function only
-- ----------------------------------------------------------------------------
alter table public.flappy_scores enable row level security;

drop policy if exists "flappy public read" on public.flappy_scores;
create policy "flappy public read" on public.flappy_scores
  for select to anon, authenticated
  using (true);

-- Remove open insert (old policy allowed unlimited duplicate inserts)
drop policy if exists "flappy public insert" on public.flappy_scores;

drop policy if exists "flappy admin all" on public.flappy_scores;
create policy "flappy admin all" on public.flappy_scores
  for all to authenticated
  using (true)
  with check (true);

grant select on public.flappy_scores to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Submit RPC: claim name / update best / reject stolen names
-- ----------------------------------------------------------------------------
drop function if exists public.flappy_submit_score(text, integer, text);

create or replace function public.flappy_submit_score(
  p_name      text,
  p_score     integer,
  p_client_id text
)
returns table (
  ok          boolean,
  status      text,   -- created | updated | not_better | name_taken | bad_name | bad_score | bad_client
  best_score  integer,
  player_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name   text := btrim(p_name);
  v_client text := btrim(p_client_id);
  r        public.flappy_scores%rowtype;
begin
  if v_name is null or char_length(v_name) < 1 or char_length(v_name) > 24 then
    return query select false, 'bad_name'::text, 0, null::text;
    return;
  end if;

  if p_score is null or p_score < 1 or p_score > 100000 then
    return query select false, 'bad_score'::text, 0, v_name;
    return;
  end if;

  if v_client is null or char_length(v_client) < 4 or char_length(v_client) > 80 then
    return query select false, 'bad_client'::text, 0, v_name;
    return;
  end if;

  -- Look up claimed name (case-insensitive)
  select * into r
    from public.flappy_scores s
   where lower(btrim(s.player_name)) = lower(v_name)
   limit 1;

  if not found then
    insert into public.flappy_scores (player_name, score, client_id)
    values (v_name, p_score, v_client)
    returning * into r;
    return query select true, 'created'::text, r.score, r.player_name;
    return;
  end if;

  -- Name taken by another device
  if r.client_id is distinct from v_client then
    return query select false, 'name_taken'::text, r.score, r.player_name;
    return;
  end if;

  -- Same device: only improve the best score
  if p_score > r.score then
    update public.flappy_scores
       set score = p_score,
           updated_at = now(),
           player_name = v_name  -- keep preferred casing from latest save
     where id = r.id
    returning * into r;
    return query select true, 'updated'::text, r.score, r.player_name;
    return;
  end if;

  return query select true, 'not_better'::text, r.score, r.player_name;
end;
$$;

revoke all on function public.flappy_submit_score(text, integer, text) from public;
grant execute on function public.flappy_submit_score(text, integer, text) to anon, authenticated;

-- Convenience view
drop view if exists public.flappy_leaderboard;
create view public.flappy_leaderboard
  with (security_invoker = off)
as
  select id, created_at, updated_at, btrim(player_name) as player_name, score
    from public.flappy_scores
   order by score desc, updated_at asc
   limit 50;

grant select on public.flappy_leaderboard to anon, authenticated;
