-- =============================================================================
-- HOTFIX #2: saves fail with: function digest(text, unknown) does not exist
-- (even fair scores of 1 fail). Cast the algorithm argument to text.
-- Run whole file in Supabase SQL Editor → Run.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- Only patch the digest line inside both submit functions by recreating them.
-- (Keep same anti-cheat rules.)

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
  v_payload  text;
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

  select count(*) into v_subs from public.game_submit_log g
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

  v_payload := v_ticket.salt || '|' || p_score::text || '|' || p_duration_ms::text
            || '|' || p_events::text || '|' || v_client || '|flappy';
  -- bytea + explicit text cast (fixes: digest(text, unknown) does not exist)
  v_expect := encode(
    extensions.digest(convert_to(v_payload, 'UTF8'), 'sha256'::text),
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
      update public.flappy_scores set score = p_score, updated_at = now(), player_name = v_name
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
  v_payload  text;
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

  select count(*) into v_subs from public.game_submit_log g
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

  v_payload := v_ticket.salt || '|' || p_score::text || '|' || p_duration_ms::text
            || '|' || p_events::text || '|' || v_client || '|drift';
  v_expect := encode(
    extensions.digest(convert_to(v_payload, 'UTF8'), 'sha256'::text),
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
      update public.drift_scores set score = p_score, updated_at = now(), player_name = v_name
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
