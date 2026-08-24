-- Language Battle: initial schema (spec section 4)
-- Tables are created in dependency order (voice_recordings needs both
-- rounds and training_rounds to exist first).

create extension if not exists pgcrypto;

-- =========================================================================
-- Users and profiles
-- =========================================================================

create table users (
  id uuid primary key references auth.users on delete cascade,
  username text unique,
  avatar_url text,
  native_language text,
  created_at timestamptz not null default now()
);

create table user_languages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  language_code text not null,
  role text not null check (role in ('native','learning')),
  cefr_level text,
  elo integer not null default 1000,
  league text not null default 'bronze',
  unique (user_id, language_code, role)
);

create index idx_user_languages_user on user_languages(user_id);

-- =========================================================================
-- Matches and rounds (PvP: Состязание / Дуэль)
-- =========================================================================

create table matches (
  id uuid primary key default gen_random_uuid(),
  player_a_id uuid references users(id),
  player_b_id uuid references users(id),
  game_mode text not null check (game_mode in ('sparring','native_duel')),
  language_pair text,
  is_bot_opponent boolean not null default false,
  status text not null check (status in ('matchmaking','in_progress','completed','abandoned')),
  winner_id uuid references users(id),
  elo_change_a integer,
  elo_change_b integer,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index idx_matches_player_a on matches(player_a_id);
create index idx_matches_player_b on matches(player_b_id);
create index idx_matches_status on matches(status);

create table rounds (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references matches(id) on delete cascade,
  round_number integer not null,
  generated_phrase text,
  phrase_meaning_context text,
  created_at timestamptz not null default now(),
  unique (match_id, round_number)
);

create index idx_rounds_match on rounds(match_id);

-- =========================================================================
-- Solo mode ("Одиночная Игра") session/round containers.
-- Created before voice_recordings, which references training_rounds.
-- =========================================================================

create table training_sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  target_language text,
  reference_elo integer,
  created_at timestamptz not null default now()
);

create index idx_training_sessions_user on training_sessions(user_id);

create table training_rounds (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references training_sessions(id) on delete cascade,
  round_number integer not null,
  generated_phrase text,
  final_score integer check (final_score between 1 and 10),
  created_at timestamptz not null default now(),
  unique (session_id, round_number)
);

create index idx_training_rounds_session on training_rounds(session_id);

-- =========================================================================
-- Voice recordings + evaluation (shared by PvP and Solo)
-- =========================================================================

create table voice_recordings (
  id uuid primary key default gen_random_uuid(),
  round_id uuid references rounds(id) on delete cascade,
  training_round_id uuid references training_rounds(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  recording_slot text not null check (recording_slot in ('native','target')),
  language_code text,
  audio_storage_path text not null,
  duration_seconds numeric,
  transcript text,
  word_confidences jsonb,
  created_at timestamptz not null default now(),
  constraint voice_recordings_exactly_one_parent check (
    (round_id is not null and training_round_id is null)
    or (round_id is null and training_round_id is not null)
  )
);

create index idx_voice_recordings_round on voice_recordings(round_id);
create index idx_voice_recordings_training_round on voice_recordings(training_round_id);
create index idx_voice_recordings_user on voice_recordings(user_id);

create table grammar_errors (
  id uuid primary key default gen_random_uuid(),
  voice_recording_id uuid not null references voice_recordings(id) on delete cascade,
  offset_start integer,
  length integer,
  message text,
  replacement text,
  category text check (category in ('grammar','spelling','style')),
  suppressed boolean not null default false,
  created_at timestamptz not null default now()
);

create index idx_grammar_errors_recording on grammar_errors(voice_recording_id);

create table round_scores (
  id uuid primary key default gen_random_uuid(),
  round_id uuid not null references rounds(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  score integer check (score between 1 and 10),
  ai_feedback text,
  scored_at timestamptz not null default now(),
  unique (round_id, user_id)
);

create index idx_round_scores_round on round_scores(round_id);

create table evaluation_jobs (
  id uuid primary key default gen_random_uuid(),
  voice_recording_id uuid not null references voice_recordings(id) on delete cascade,
  status text not null check (status in ('pending','processing','done','failed')) default 'pending',
  worker_id text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index idx_evaluation_jobs_status on evaluation_jobs(status);
create index idx_evaluation_jobs_recording on evaluation_jobs(voice_recording_id);

-- =========================================================================
-- Matchmaking (background search, Фаза 3 — table created now per spec)
-- =========================================================================

create table matchmaking_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references users(id) on delete cascade,
  game_mode text not null check (game_mode in ('sparring','native_duel')),
  native_language text,
  target_language text,
  countrymen_only boolean not null default false,
  elo integer,
  status text not null check (status in ('searching','found','accepted','expired','cancelled')),
  created_at timestamptz not null default now(),
  notified_at timestamptz,
  expires_at timestamptz
);

create index idx_matchmaking_tickets_user on matchmaking_tickets(user_id);
create index idx_matchmaking_tickets_status on matchmaking_tickets(status);

-- =========================================================================
-- Meta-progression
-- =========================================================================

create table currency_wallets (
  user_id uuid primary key references users(id) on delete cascade,
  soft_currency integer not null default 0,
  hard_currency integer not null default 0
);

create table cosmetic_items (
  id uuid primary key default gen_random_uuid(),
  name text,
  type text check (type in ('avatar_skin','profile_frame','emote','victory_animation')),
  price_soft integer,
  price_hard integer,
  rarity text
);

create table user_inventory (
  user_id uuid references users(id) on delete cascade,
  item_id uuid references cosmetic_items(id) on delete cascade,
  acquired_at timestamptz not null default now(),
  primary key (user_id, item_id)
);

create table battle_pass_seasons (
  id uuid primary key default gen_random_uuid(),
  season_name text,
  start_date date,
  end_date date
);

create table battle_pass_progress (
  user_id uuid references users(id) on delete cascade,
  season_id uuid references battle_pass_seasons(id) on delete cascade,
  xp integer not null default 0,
  tier integer not null default 0,
  has_premium boolean not null default false,
  primary key (user_id, season_id)
);

-- =========================================================================
-- Social
-- =========================================================================

create table friendships (
  user_id uuid references users(id) on delete cascade,
  friend_id uuid references users(id) on delete cascade,
  status text check (status in ('pending','accepted','blocked')),
  primary key (user_id, friend_id)
);

create table reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references users(id) on delete cascade,
  reported_user_id uuid references users(id),
  match_id uuid references matches(id),
  reason text,
  status text check (status in ('open','reviewed','resolved')) default 'open',
  created_at timestamptz not null default now()
);

-- =========================================================================
-- New-auth-user bootstrap: every auth.users row gets a public.users profile
-- and an empty wallet, so signup alone is enough to show up in Table Editor.
-- =========================================================================

create function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.users (id) values (new.id);
  insert into public.currency_wallets (user_id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();
