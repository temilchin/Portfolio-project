-- =============================================================================
-- Forest Stack 3D — leaderboard + anti-cheat
--
-- Rules (same family as flappy / drift):
--   1. player_name UNIQUE (case-insensitive).
--   2. First save claims the name for that browser client_id.
--   3. Same device + name → UPDATE only if score is HIGHER.
--   4. Other device + claimed name → name_taken.
--   5. Scores need a one-time run ticket from game_begin_run('stack', ...).
--   6. Server wall-clock duration caps max score.
--   7. Proof HMAC (ticket salt) + rate limits.
--
-- Score meaning: tower height (layers placed successfully). Perfects are
-- client-side juice only; submitted score = layers (anti-cheat simple).
--
-- Run in: Supabase Dashboard → SQL Editor → paste ALL → Run.
-- Safe to re-run (idempotent).
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- ----------------------------------------------------------------------------
-- Shared tickets: allow game = 'stack'
-- ----------------------------------------------------------------------------
create table if not exists public.game_run_tickets (
  id              uuid primary key default gen_random_uuid(),
  game            text not null,
  client_id       text not null check (char_length(client_id) between 4 and 80),
  salt            text not null,
  issued_at       timestamptz not null default now(),
  expires_at      timestamptz not null,
  used_at         timestamptz,
  score_submitted integer
);

-- Relax / replace game check to include stack
do $$
begin
  alter table public.game_run_tickets drop constraint if exists game_run_tickets_game_check;
exception when undefined_object then null;
end $$;

alter table public.game_run_tickets
  drop constraint if exists game_run_tickets_game_check;

alter table public.game_run_tickets
  add constraint game_run_tickets_game_check
  check (game in ('flappy', 'drift', 'stack'));

create index if not exists game_run_tickets_client_idx
  on public.game_run_tickets (client_id, game, issued_at desc);

create table if not exists public.game_submit_log (
  id         uuid primary key default gen_random_uuid(),
  game       text not null,
  client_id  text not null,
  score      integer not null,
  created_at timestamptz not null default now()
);

create index if not exists game_submit_log_client_idx
  on public.game_submit_log (client_id, game, created_at desc);

alter table public.game_run_tickets enable row level security;
alter table public.game_submit_log enable row level security;
revoke all on public.game_run_tickets from public, anon, authenticated;
revoke all on public.game_submit_log from public, anon, authenticated;

-- Begin run (flappy + drift + stack)
drop function if exists public.game_begin_run(text, text);
create or replace function public.game_begin_run(
  p_game      text,
  p_client_id text
)
returns table (
  ticket_id  uuid,
  salt       text,
  issued_at  timestamptz
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_game   text := lower(btrim(p_game));
  v_client text := btrim(p_client_id);
  v_open   int;
  v_hour   int;
  v_id     uuid;
  v_salt   text;
  v_iss    timestamptz := now();
begin
  if v_game is null or v_game not in ('flappy', 'drift', 'stack') then
    raise exception 'bad_game' using errcode = '22023';
  end if;
  if v_client is null or char_length(v_client) < 4 or char_length(v_client) > 80 then
    raise exception 'bad_client' using errcode = '22023';
  end if;

  select count(*) into v_hour
    from public.game_run_tickets t
   where t.client_id = v_client
     and t.game = v_game
     and t.issued_at > now() - interval '1 hour';
  if v_hour >= 40 then
    raise exception 'rate_limited' using errcode = 'P0001';
  end if;

  select count(*) into v_open
    from public.game_run_tickets t
   where t.client_id = v_client
     and t.game = v_game
     and t.used_at is null
     and t.expires_at > now();
  if v_open >= 3 then
    update public.game_run_tickets t
       set expires_at = now() - interval '1 second'
     where t.id in (
       select id from public.game_run_tickets x
        where x.client_id = v_client and x.game = v_game
          and x.used_at is null
        order by x.issued_at asc
        limit greatest(v_open - 2, 1)
     );
  end if;

  v_id := gen_random_uuid();
  begin
    v_salt := encode(extensions.gen_random_bytes(16), 'hex');
  exception when undefined_function then
    v_salt := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  end;

  insert into public.game_run_tickets (id, game, client_id, salt, issued_at, expires_at)
  values (v_id, v_game, v_client, v_salt, v_iss, v_iss + interval '3 hours');

  return query select v_id, v_salt, v_iss;
end;
$$;

revoke all on function public.game_begin_run(text, text) from public;
grant execute on function public.game_begin_run(text, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Scores table
-- ----------------------------------------------------------------------------
create table if not exists public.stack_scores (
  id           uuid primary key default gen_random_uuid(),
  player_name  text not null,
  client_id    text not null,
  score        integer not null check (score >= 0 and score <= 5000),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create unique index if not exists stack_scores_name_unique_idx
  on public.stack_scores (lower(btrim(player_name)));

create index if not exists stack_scores_rank_idx
  on public.stack_scores (score desc, updated_at asc);

create index if not exists stack_scores_client_idx
  on public.stack_scores (client_id);

alter table public.stack_scores enable row level security;

drop policy if exists "stack public read" on public.stack_scores;
create policy "stack public read" on public.stack_scores
  for select to anon, authenticated using (true);

drop policy if exists "stack admin all" on public.stack_scores;
create policy "stack admin all" on public.stack_scores
  for all to authenticated using (true) with check (true);

grant select on public.stack_scores to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Submit RPC
-- ----------------------------------------------------------------------------
drop function if exists public.stack_submit_score(text, integer, text);
drop function if exists public.stack_submit_score(text, integer, text, uuid, integer, integer, text);

create or replace function public.stack_submit_score(
  p_name        text,
  p_score       integer,
  p_client_id   text,
  p_ticket_id   uuid,
  p_duration_ms integer,
  p_events      integer,
  p_proof       text
)
returns table (
  ok          boolean,
  status      text,
  best_score  integer,
  player_name text
)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_name      text := btrim(p_name);
  v_client    text := btrim(p_client_id);
  v_proof     text := lower(btrim(coalesce(p_proof, '')));
  v_expect    text;
  v_ticket    public.game_run_tickets%rowtype;
  v_server_ms bigint;
  v_max_score integer;
  v_subs      int;
  r           public.stack_scores%rowtype;
  -- ~450ms theoretical min per layer with speed; +slack
  c_ms_per_point constant numeric := 450;
  c_abs_max      constant integer := 5000;
begin
  if v_name is null or char_length(v_name) < 1 or char_length(v_name) > 24 then
    return query select false, 'bad_name'::text, 0, null::text;
    return;
  end if;

  if p_score is null or p_score < 1 or p_score > c_abs_max then
    return query select false, 'bad_score'::text, 0, v_name;
    return;
  end if;

  if v_client is null or char_length(v_client) < 4 or char_length(v_client) > 80 then
    return query select false, 'bad_client'::text, 0, v_name;
    return;
  end if;

  if p_ticket_id is null or p_duration_ms is null or p_duration_ms < 0
     or p_events is null or p_events < 0 or p_events > 1000000
     or v_proof is null or char_length(v_proof) < 32 then
    return query select false, 'bad_ticket'::text, 0, v_name;
    return;
  end if;

  select count(*) into v_subs
    from public.game_submit_log g
   where g.client_id = v_client
     and g.game = 'stack'
     and g.created_at > now() - interval '1 hour';
  if v_subs >= 25 then
    return query select false, 'rate_limited'::text, 0, v_name;
    return;
  end if;

  select * into v_ticket
    from public.game_run_tickets t
   where t.id = p_ticket_id
   for update;

  if not found then
    return query select false, 'bad_ticket'::text, 0, v_name;
    return;
  end if;

  if v_ticket.game is distinct from 'stack'
     or v_ticket.client_id is distinct from v_client then
    return query select false, 'bad_ticket'::text, 0, v_name;
    return;
  end if;

  if v_ticket.used_at is not null then
    return query select false, 'ticket_used'::text, 0, v_name;
    return;
  end if;

  if v_ticket.expires_at < now() then
    return query select false, 'expired'::text, 0, v_name;
    return;
  end if;

  v_server_ms := greatest(0, floor(extract(epoch from (now() - v_ticket.issued_at)) * 1000))::bigint;

  v_max_score := least(
    c_abs_max,
    greatest(0, floor(v_server_ms::numeric / c_ms_per_point)::integer) + 1
  );

  if p_score > v_max_score then
    update public.game_run_tickets
       set used_at = now(), score_submitted = p_score
     where id = v_ticket.id;
    return query select false, 'impossible'::text, 0, v_name;
    return;
  end if;

  if p_duration_ms > v_server_ms + 8000
     or p_duration_ms < greatest(0, v_server_ms - 60000) * 0.35 then
    update public.game_run_tickets
       set used_at = now(), score_submitted = p_score
     where id = v_ticket.id;
    return query select false, 'impossible'::text, 0, v_name;
    return;
  end if;

  -- Each successful place = 1 event; need ~1 event per layer
  if p_score >= 2 and p_events < p_score then
    update public.game_run_tickets
       set used_at = now(), score_submitted = p_score
     where id = v_ticket.id;
    return query select false, 'impossible'::text, 0, v_name;
    return;
  end if;

  v_expect := encode(
    extensions.digest(
      (v_ticket.salt || '|' || p_score::text || '|' || p_duration_ms::text
        || '|' || p_events::text || '|' || v_client || '|stack')::text,
      'sha256'::text
    ),
    'hex'
  );

  if v_proof is distinct from v_expect then
    update public.game_run_tickets
       set used_at = now(), score_submitted = p_score
     where id = v_ticket.id;
    return query select false, 'bad_proof'::text, 0, v_name;
    return;
  end if;

  select * into r
    from public.stack_scores s
   where lower(btrim(s.player_name)) = lower(v_name)
   limit 1;

  if found then
    if r.client_id is distinct from v_client then
      return query select false, 'name_taken'::text, r.score, r.player_name;
      return;
    end if;
    update public.game_run_tickets
       set used_at = now(), score_submitted = p_score
     where id = v_ticket.id;
    insert into public.game_submit_log (game, client_id, score)
    values ('stack', v_client, p_score);
    if p_score > r.score then
      update public.stack_scores
         set score = p_score, updated_at = now(), player_name = v_name
       where id = r.id;
      return query select true, 'updated'::text, p_score, v_name;
      return;
    end if;
    return query select true, 'not_better'::text, r.score, r.player_name;
    return;
  end if;

  update public.game_run_tickets
     set used_at = now(), score_submitted = p_score
   where id = v_ticket.id;
  insert into public.game_submit_log (game, client_id, score)
  values ('stack', v_client, p_score);
  insert into public.stack_scores (player_name, score, client_id)
  values (v_name, p_score, v_client)
  returning * into r;
  return query select true, 'created'::text, r.score, r.player_name;
end;
$$;

revoke all on function public.stack_submit_score(text, integer, text, uuid, integer, integer, text) from public;
grant execute on function public.stack_submit_score(text, integer, text, uuid, integer, integer, text) to anon, authenticated;
