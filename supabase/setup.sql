-- ═══════════════════════════════════════════════════════════════════════════
-- Quiz security setup. Run once per Supabase project (SQL Editor). Safe to re-run.
--
-- Also needed in the dashboard:
--   1. Authentication → Sign In / Providers → enable "Allow anonymous sign-ins"
--   2. Authentication → Users → Add user (the host's email + password)
--   3. Run:  insert into public.quiz_hosts (user_id)
--            select id from auth.users where email = '<host email>';
-- ═══════════════════════════════════════════════════════════════════════════

-- Players table (no-op if it already exists)
create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  username text not null unique,
  answers jsonb default '{}'::jsonb,
  score integer default 0,
  finished boolean default false,
  created_at timestamp default now()
);

-- Live leaderboard updates
do $$ begin
  if not exists (select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'players') then
    alter publication supabase_realtime add table public.players;
  end if;
end $$;

-- Who is allowed to host
create table if not exists public.quiz_hosts (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.quiz_hosts enable row level security;
-- (no policies: only readable through is_quiz_host() below)

create or replace function public.is_quiz_host()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.quiz_hosts where user_id = auth.uid());
$$;
revoke all on function public.is_quiz_host() from public;
grant execute on function public.is_quiz_host() to anon, authenticated;

-- Tie each player row to the browser session that created it
alter table public.players add column if not exists user_id uuid default auth.uid()
  references auth.users(id) on delete cascade;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'players_user_id_key') then
    alter table public.players add constraint players_user_id_key unique (user_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'players_username_len') then
    alter table public.players add constraint players_username_len
      check (char_length(username) between 1 and 30) not valid;
  end if;
end $$;

-- Row Level Security: replace any existing policies on players
alter table public.players enable row level security;
do $$ declare pol record; begin
  for pol in select policyname from pg_policies where schemaname = 'public' and tablename = 'players' loop
    execute format('drop policy %I on public.players', pol.policyname);
  end loop;
end $$;

create policy "leaderboard is public" on public.players
  for select to anon, authenticated using (true);

create policy "players create their own entry" on public.players
  for insert to authenticated
  with check (user_id = auth.uid() and score = 0 and finished = false);

create policy "players update their own unfinished entry" on public.players
  for update to authenticated
  using (user_id = auth.uid() and finished = false)
  with check (user_id = auth.uid());

create policy "only hosts can delete" on public.players
  for delete to authenticated using (public.is_quiz_host());

-- Private Realtime channel for host → presentation control (RLS is on by default here)
drop policy if exists "quiz hosts receive control" on realtime.messages;
drop policy if exists "quiz hosts send control" on realtime.messages;
create policy "quiz hosts receive control" on realtime.messages
  for select to authenticated
  using (realtime.topic() = 'quiz-control' and public.is_quiz_host());
create policy "quiz hosts send control" on realtime.messages
  for insert to authenticated
  with check (realtime.topic() = 'quiz-control' and public.is_quiz_host());

-- ═══ Hidden answer key + server-side scoring ═══════════════════════════════
-- Fill in the answers in Table Editor → quiz_answers (question 1, 2, 3… → A/B/C/D).
-- Never commit the answers to this repo: it is public.
create table if not exists public.quiz_answers (
  question integer primary key check (question > 0),
  answer   text not null check (answer in ('A','B','C','D'))
);
alter table public.quiz_answers enable row level security;
drop policy if exists "hosts read answer key" on public.quiz_answers;
create policy "hosts read answer key" on public.quiz_answers
  for select to authenticated using (public.is_quiz_host());

alter table public.players add column if not exists answered integer default 0;

-- Score is 0 until the player submits, then marked against the hidden key.
create or replace function public.players_compute_score()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  new.answered := (select count(*) from jsonb_object_keys(coalesce(new.answers, '{}'::jsonb)));
  if new.finished then
    new.score := (select count(*) from public.quiz_answers a
                  where new.answers ->> (a.question - 1)::text = (ascii(a.answer) - 65)::text);
  else
    new.score := 0;
  end if;
  return new;
end $$;
drop trigger if exists players_compute_score on public.players;
create trigger players_compute_score before insert or update on public.players
  for each row execute function public.players_compute_score();

-- Players' picks are private: everyone sees name/progress/score, not answers.
revoke select on public.players from anon, authenticated;
grant select (id, username, score, finished, answered, created_at, user_id)
  on public.players to anon, authenticated;

-- A player can fetch their own saved picks (to resume after a refresh)
create or replace function public.my_answers()
returns jsonb
language sql stable security definer set search_path = ''
as $$ select answers from public.players where user_id = auth.uid() $$;
revoke all on function public.my_answers() from public;
grant execute on function public.my_answers() to authenticated;

-- If you fix an answer after people have submitted, re-mark everyone with:
--   update public.players set finished = finished where finished;
