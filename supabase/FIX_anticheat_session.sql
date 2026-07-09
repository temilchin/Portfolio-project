-- =============================================================================
-- HOTFIX: "Session not ready" — game_begin_run broken on Supabase
--
-- Root cause (verified via live API):
--   function gen_random_bytes(integer) does not exist
-- Because SECURITY DEFINER used search_path = public only, and on Supabase
-- pgcrypto lives in schema "extensions".
--
-- Run this ONCE in Supabase SQL Editor (whole file → Run).
-- Then hard-refresh the games.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- Recreate begin_run with extensions on the search_path
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
  if v_game is null or v_game not in ('flappy', 'drift') then
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

-- Fix digest() path in submit functions (same extensions issue)
drop function if exists public.flappy_submit_score(text, integer, text, uuid, integer, integer, text);
create or replace function public.flappy_submit_score(
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
  v_name     text := btrim(p_name);
  v_client   text := btrim(p_client_id);
  v_proof    text := lower(btrim(coalesce(p_proof, '')));
  v_expect   text;
  v_ticket   public.game_run_tickets%rowtype;
  v_server_ms bigint;
  v_max_score integer;
  v_subs     int;
  r          public.flappy_scores%rowtype;
  c_ms_per_point constant numeric := 1350;
  c_abs_max      constant integer := 5000;
begin
  if v_name is null or char_length(v_name) < 1 or char_length(v_name) > 24 then
    return query select false, 'bad_name'::text, 0, null::text; return;
  end if;
  if p_score is null or p_score < 1 or p_score > c_abs_max then
    return query select false, 'bad_score'::text, 0, v_name; return;
  end if;
  if v_client is null or char_length(v_client) < 4 or char_length(v_client) > 80 then
    return query select false, 'bad_client'::text, 0, v_name; return;
  end if;
  if p_ticket_id is null or p_duration_ms is null or p_duration_ms < 0
     or p_events is null or p_events < 0 or p_events > 1000000
     or v_proof is null or char_length(v_proof) < 32 then
    return query select false, 'bad_ticket'::text, 0, v_name; return;
  end if;

  select count(*) into v_subs
    from public.game_submit_log g
   where g.client_id = v_client and g.game = 'flappy'
     and g.created_at > now() - interval '1 hour';
  if v_subs >= 25 then
    return query select false, 'rate_limited'::text, 0, v_name; return;
  end if;

  select * into v_ticket from public.game_run_tickets t where t.id = p_ticket_id for update;
  if not found then
    return query select false, 'bad_ticket'::text, 0, v_name; return;
  end if;
  if v_ticket.game is distinct from 'flappy' or v_ticket.client_id is distinct from v_client then
    return query select false, 'bad_ticket'::text, 0, v_name; return;
  end if;
  if v_ticket.used_at is not null then
    return query select false, 'ticket_used'::text, 0, v_name; return;
  end if;
  if v_ticket.expires_at < now() then
    return query select false, 'expired'::text, 0, v_name; return;
  end if;

  v_server_ms := greatest(0, floor(extract(epoch from (now() - v_ticket.issued_at)) * 1000))::bigint;
  v_max_score := least(c_abs_max, greatest(0, floor(v_server_ms::numeric / c_ms_per_point)::integer) + 1);

  if p_score > v_max_score then
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    return query select false, 'impossible'::text, 0, v_name; return;
  end if;
  if p_duration_ms > v_server_ms + 8000
     or p_duration_ms < greatest(0, v_server_ms - 60000) * 0.35 then
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    return query select false, 'impossible'::text, 0, v_name; return;
  end if;
  if p_score >= 3 and p_events < greatest(1, p_score / 3) then
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    return query select false, 'impossible'::text, 0, v_name; return;
  end if;

  v_expect := encode(
    extensions.digest(
      (v_ticket.salt || '|' || p_score::text || '|' || p_duration_ms::text
        || '|' || p_events::text || '|' || v_client || '|flappy')::text,
      'sha256'::text
    ),
    'hex'
  );
  if v_proof is distinct from v_expect then
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    return query select false, 'bad_proof'::text, 0, v_name; return;
  end if;

  select * into r from public.flappy_scores s
   where lower(btrim(s.player_name)) = lower(v_name) limit 1;

  if found then
    if r.client_id is distinct from v_client then
      return query select false, 'name_taken'::text, r.score, r.player_name; return;
    end if;
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    insert into public.game_submit_log (game, client_id, score) values ('flappy', v_client, p_score);
    if p_score > r.score then
      update public.flappy_scores
         set score = p_score, updated_at = now(), player_name = v_name
       where id = r.id returning * into r;
      return query select true, 'updated'::text, r.score, r.player_name; return;
    end if;
    return query select true, 'not_better'::text, r.score, r.player_name; return;
  end if;

  update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
  insert into public.game_submit_log (game, client_id, score) values ('flappy', v_client, p_score);
  insert into public.flappy_scores (player_name, score, client_id)
  values (v_name, p_score, v_client) returning * into r;
  return query select true, 'created'::text, r.score, r.player_name;
end;
$$;

revoke all on function public.flappy_submit_score(text, integer, text, uuid, integer, integer, text) from public;
grant execute on function public.flappy_submit_score(text, integer, text, uuid, integer, integer, text) to anon, authenticated;

drop function if exists public.drift_submit_score(text, integer, text, uuid, integer, integer, text);
create or replace function public.drift_submit_score(
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
  v_name     text := btrim(p_name);
  v_client   text := btrim(p_client_id);
  v_proof    text := lower(btrim(coalesce(p_proof, '')));
  v_expect   text;
  v_ticket   public.game_run_tickets%rowtype;
  v_server_ms bigint;
  v_max_score integer;
  v_subs     int;
  r          public.drift_scores%rowtype;
  c_pts_per_sec  constant numeric := 700;
  c_abs_max      constant integer := 5000000;
begin
  if v_name is null or char_length(v_name) < 1 or char_length(v_name) > 24 then
    return query select false, 'bad_name'::text, 0, null::text; return;
  end if;
  if p_score is null or p_score < 1 or p_score > c_abs_max then
    return query select false, 'bad_score'::text, 0, v_name; return;
  end if;
  if v_client is null or char_length(v_client) < 4 or char_length(v_client) > 80 then
    return query select false, 'bad_client'::text, 0, v_name; return;
  end if;
  if p_ticket_id is null or p_duration_ms is null or p_duration_ms < 0
     or p_events is null or p_events < 0 or p_events > 10000000
     or v_proof is null or char_length(v_proof) < 32 then
    return query select false, 'bad_ticket'::text, 0, v_name; return;
  end if;

  select count(*) into v_subs
    from public.game_submit_log g
   where g.client_id = v_client and g.game = 'drift'
     and g.created_at > now() - interval '1 hour';
  if v_subs >= 25 then
    return query select false, 'rate_limited'::text, 0, v_name; return;
  end if;

  select * into v_ticket from public.game_run_tickets t where t.id = p_ticket_id for update;
  if not found then
    return query select false, 'bad_ticket'::text, 0, v_name; return;
  end if;
  if v_ticket.game is distinct from 'drift' or v_ticket.client_id is distinct from v_client then
    return query select false, 'bad_ticket'::text, 0, v_name; return;
  end if;
  if v_ticket.used_at is not null then
    return query select false, 'ticket_used'::text, 0, v_name; return;
  end if;
  if v_ticket.expires_at < now() then
    return query select false, 'expired'::text, 0, v_name; return;
  end if;

  v_server_ms := greatest(0, floor(extract(epoch from (now() - v_ticket.issued_at)) * 1000))::bigint;
  v_max_score := least(c_abs_max, greatest(0, floor((v_server_ms::numeric / 1000.0) * c_pts_per_sec)::integer) + 500);

  if p_score > v_max_score then
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    return query select false, 'impossible'::text, 0, v_name; return;
  end if;
  if p_duration_ms > v_server_ms + 8000
     or p_duration_ms < greatest(0, v_server_ms - 60000) * 0.35 then
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    return query select false, 'impossible'::text, 0, v_name; return;
  end if;
  if p_score >= 2000 and p_events < 30 then
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    return query select false, 'impossible'::text, 0, v_name; return;
  end if;

  v_expect := encode(
    extensions.digest(
      (v_ticket.salt || '|' || p_score::text || '|' || p_duration_ms::text
        || '|' || p_events::text || '|' || v_client || '|drift')::text,
      'sha256'::text
    ),
    'hex'
  );
  if v_proof is distinct from v_expect then
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    return query select false, 'bad_proof'::text, 0, v_name; return;
  end if;

  select * into r from public.drift_scores s
   where lower(btrim(s.player_name)) = lower(v_name) limit 1;

  if found then
    if r.client_id is distinct from v_client then
      return query select false, 'name_taken'::text, r.score, r.player_name; return;
    end if;
    update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
    insert into public.game_submit_log (game, client_id, score) values ('drift', v_client, p_score);
    if p_score > r.score then
      update public.drift_scores
         set score = p_score, updated_at = now(), player_name = v_name
       where id = r.id returning * into r;
      return query select true, 'updated'::text, r.score, r.player_name; return;
    end if;
    return query select true, 'not_better'::text, r.score, r.player_name; return;
  end if;

  update public.game_run_tickets set used_at = now(), score_submitted = p_score where id = v_ticket.id;
  insert into public.game_submit_log (game, client_id, score) values ('drift', v_client, p_score);
  insert into public.drift_scores (player_name, score, client_id)
  values (v_name, p_score, v_client) returning * into r;
  return query select true, 'created'::text, r.score, r.player_name;
end;
$$;

revoke all on function public.drift_submit_score(text, integer, text, uuid, integer, integer, text) from public;
grant execute on function public.drift_submit_score(text, integer, text, uuid, integer, integer, text) to anon, authenticated;

-- Self-check (should return one row with ticket_id + salt)
select * from public.game_begin_run('flappy', 'sql_fix_ok_001');
