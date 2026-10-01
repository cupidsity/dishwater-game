-- run once in the supabase sql editor.
--
-- rls is on with no policies, so the publishable key cannot touch the tables
-- directly. the three functions below are the only things the browser may call.

create table if not exists public.leaderboard (
  player_id  uuid primary key,
  name       text not null,
  best_score integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.leaderboard enable row level security;

create index if not exists leaderboard_ranking
  on public.leaderboard (best_score desc, updated_at asc);

-- a run is opened when a game starts and stamped with the server's clock, so a
-- score can be checked against how long the game could really have lasted. the
-- browser never gets to say when it started
create table if not exists public.leaderboard_runs (
  run_id     uuid primary key default gen_random_uuid(),
  player_id  uuid not null,
  started_at timestamptz not null default now()
);

alter table public.leaderboard_runs enable row level security;

create index if not exists leaderboard_runs_by_player
  on public.leaderboard_runs (player_id, started_at desc);

create or replace function public.start_run(player uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_run_id uuid;
begin
  if player is null then
    raise exception 'missing player';
  end if;

  -- abandoned runs pile up otherwise, nothing legitimate lasts a day
  delete from public.leaderboard_runs where started_at < now() - interval '1 day';

  -- one game cannot start faster than a player can click play again, so this
  -- only gets in the way of a script opening runs in bulk to submit later
  if exists (
    select 1 from public.leaderboard_runs
    where player_id = player and started_at > now() - interval '2 seconds'
  ) then
    raise exception 'starting runs too fast';
  end if;

  insert into public.leaderboard_runs (player_id)
  values (player)
  returning run_id into new_run_id;

  return new_run_id;
end;
$$;

-- the spawn interval bottoms out at 0.25s and the best cat is worth 6, so even a
-- flawless run averages well under 12 points a second. pausing and background
-- tabs only make wall clock time longer than game time, so this never cuts off
-- an honest score. the run is deleted on use so it cannot be replayed.
-- the name is only set the first time a player appears, so a leaked id cannot be
-- used to rename anyone, and the score only ever moves up.
create or replace function public.submit_score(
  player uuid,
  player_name text,
  new_score integer,
  run uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tidy_name text;
  run_started_at timestamptz;
  seconds_played double precision;
begin
  delete from public.leaderboard_runs
  where run_id = run and player_id = player
  returning started_at into run_started_at;

  if run_started_at is null then
    raise exception 'unknown run';
  end if;

  seconds_played := extract(epoch from now() - run_started_at);

  if new_score is null or new_score < 0 or new_score > 60 + floor(seconds_played * 12) then
    raise exception 'score out of range';
  end if;

  tidy_name := left(btrim(coalesce(player_name, '')), 16);
  if tidy_name = '' then
    tidy_name := 'anon';
  end if;

  insert into public.leaderboard (player_id, name, best_score)
  values (player, tidy_name, new_score)
  on conflict (player_id) do update
    set best_score = greatest(public.leaderboard.best_score, excluded.best_score),
        updated_at = now();
end;
$$;

-- player ids are deliberately not returned, an id is the only thing standing
-- between a stranger and writing to someone else's row.
create or replace function public.get_leaderboard(board_size integer default 10)
returns table (name text, best_score integer)
language sql
security definer
stable
set search_path = public
as $$
  select l.name, l.best_score
  from public.leaderboard l
  order by l.best_score desc, l.updated_at asc
  limit least(greatest(coalesce(board_size, 10), 1), 100);
$$;

-- the old version took a score with no run and is how fake scores got in
drop function if exists public.submit_score(uuid, text, integer);

revoke all on public.leaderboard from anon, authenticated;
revoke all on public.leaderboard_runs from anon, authenticated;

-- postgres lets anyone execute a new function unless told otherwise
revoke execute on function public.start_run(uuid) from public;
revoke execute on function public.submit_score(uuid, text, integer, uuid) from public;
revoke execute on function public.get_leaderboard(integer) from public;

grant execute on function public.start_run(uuid) to anon, authenticated;
grant execute on function public.submit_score(uuid, text, integer, uuid) to anon, authenticated;
grant execute on function public.get_leaderboard(integer) to anon, authenticated;
