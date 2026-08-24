-- Language Battle: Row Level Security policies + Storage bucket for audio.
--
-- Storage path convention (bucket "voice-recordings"):
--   PvP:   match/{match_id}/{round_id}/{user_id}_{slot}.m4a
--   Solo:  training/{session_id}/{training_round_id}/{user_id}_{attempt}.m4a

-- =========================================================================
-- Enable RLS everywhere
-- =========================================================================

alter table users enable row level security;
alter table user_languages enable row level security;
alter table matches enable row level security;
alter table rounds enable row level security;
alter table training_sessions enable row level security;
alter table training_rounds enable row level security;
alter table voice_recordings enable row level security;
alter table grammar_errors enable row level security;
alter table round_scores enable row level security;
alter table evaluation_jobs enable row level security;
alter table matchmaking_tickets enable row level security;
alter table currency_wallets enable row level security;
alter table cosmetic_items enable row level security;
alter table user_inventory enable row level security;
alter table battle_pass_seasons enable row level security;
alter table battle_pass_progress enable row level security;
alter table friendships enable row level security;
alter table reports enable row level security;

-- =========================================================================
-- users — public-ish profile data, editable only by owner
-- =========================================================================

create policy "users: anyone authenticated can view profiles"
  on users for select
  to authenticated
  using (true);

create policy "users: owner can update own profile"
  on users for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- =========================================================================
-- user_languages — visible to all (leaderboards, opponent CEFR level),
-- editable only by owner
-- =========================================================================

create policy "user_languages: anyone authenticated can view"
  on user_languages for select
  to authenticated
  using (true);

create policy "user_languages: owner can insert own"
  on user_languages for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "user_languages: owner can update own"
  on user_languages for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "user_languages: owner can delete own"
  on user_languages for delete
  to authenticated
  using (user_id = auth.uid());

-- =========================================================================
-- matches — visible/editable only by the two participants.
-- No client insert policy on purpose: matches are created by a trusted
-- context (Supabase Studio for the Wizard-of-Oz phase now, the matchmaking
-- Edge Function later) using the service role, which bypasses RLS.
-- =========================================================================

create policy "matches: participants can view"
  on matches for select
  to authenticated
  using (player_a_id = auth.uid() or player_b_id = auth.uid());

create policy "matches: participants can update"
  on matches for update
  to authenticated
  using (player_a_id = auth.uid() or player_b_id = auth.uid())
  with check (player_a_id = auth.uid() or player_b_id = auth.uid());

-- =========================================================================
-- rounds — visible/insertable only by participants of the parent match
-- =========================================================================

create policy "rounds: participants can view"
  on rounds for select
  to authenticated
  using (
    exists (
      select 1 from matches m
      where m.id = rounds.match_id
        and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
    )
  );

create policy "rounds: participants can create"
  on rounds for insert
  to authenticated
  with check (
    exists (
      select 1 from matches m
      where m.id = rounds.match_id
        and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
    )
  );

-- =========================================================================
-- training_sessions / training_rounds — owner only
-- =========================================================================

create policy "training_sessions: owner can view"
  on training_sessions for select
  to authenticated
  using (user_id = auth.uid());

create policy "training_sessions: owner can create"
  on training_sessions for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "training_rounds: owner can view"
  on training_rounds for select
  to authenticated
  using (
    exists (
      select 1 from training_sessions ts
      where ts.id = training_rounds.session_id and ts.user_id = auth.uid()
    )
  );

create policy "training_rounds: owner can create"
  on training_rounds for insert
  to authenticated
  with check (
    exists (
      select 1 from training_sessions ts
      where ts.id = training_rounds.session_id and ts.user_id = auth.uid()
    )
  );

-- =========================================================================
-- voice_recordings — visible to match participants (or training owner),
-- insertable only by the recording's own user_id
-- =========================================================================

create policy "voice_recordings: participants can view"
  on voice_recordings for select
  to authenticated
  using (
    (
      round_id is not null and exists (
        select 1 from rounds r
        join matches m on m.id = r.match_id
        where r.id = voice_recordings.round_id
          and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
      )
    )
    or (
      training_round_id is not null and exists (
        select 1 from training_rounds tr
        join training_sessions ts on ts.id = tr.session_id
        where tr.id = voice_recordings.training_round_id
          and ts.user_id = auth.uid()
      )
    )
  );

create policy "voice_recordings: owner can insert own"
  on voice_recordings for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and (
      (
        round_id is not null and exists (
          select 1 from rounds r
          join matches m on m.id = r.match_id
          where r.id = voice_recordings.round_id
            and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
        )
      )
      or (
        training_round_id is not null and exists (
          select 1 from training_rounds tr
          join training_sessions ts on ts.id = tr.session_id
          where tr.id = voice_recordings.training_round_id
            and ts.user_id = auth.uid()
        )
      )
    )
  );

-- =========================================================================
-- grammar_errors — read-only for clients, visible via the parent recording
-- =========================================================================

create policy "grammar_errors: participants can view"
  on grammar_errors for select
  to authenticated
  using (
    exists (
      select 1 from voice_recordings vr
      where vr.id = grammar_errors.voice_recording_id
        and (
          (
            vr.round_id is not null and exists (
              select 1 from rounds r
              join matches m on m.id = r.match_id
              where r.id = vr.round_id
                and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
            )
          )
          or (
            vr.training_round_id is not null and exists (
              select 1 from training_rounds tr
              join training_sessions ts on ts.id = tr.session_id
              where tr.id = vr.training_round_id and ts.user_id = auth.uid()
            )
          )
        )
    )
  );

-- =========================================================================
-- round_scores — read-only for clients on purpose. Scores are written by
-- the evaluation worker (service role) — or, during the Wizard-of-Oz phase,
-- by a human via Supabase Studio (which also uses a privileged role and
-- bypasses RLS). No authenticated client can insert/update its own score.
-- =========================================================================

create policy "round_scores: participants can view"
  on round_scores for select
  to authenticated
  using (
    exists (
      select 1 from rounds r
      join matches m on m.id = r.match_id
      where r.id = round_scores.round_id
        and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
    )
  );

-- =========================================================================
-- evaluation_jobs — the uploader can create the job and watch its status
-- =========================================================================

create policy "evaluation_jobs: owner can view"
  on evaluation_jobs for select
  to authenticated
  using (
    exists (
      select 1 from voice_recordings vr
      where vr.id = evaluation_jobs.voice_recording_id and vr.user_id = auth.uid()
    )
  );

create policy "evaluation_jobs: owner can create"
  on evaluation_jobs for insert
  to authenticated
  with check (
    exists (
      select 1 from voice_recordings vr
      where vr.id = evaluation_jobs.voice_recording_id and vr.user_id = auth.uid()
    )
  );

-- =========================================================================
-- matchmaking_tickets — owner only
-- =========================================================================

create policy "matchmaking_tickets: owner can view"
  on matchmaking_tickets for select
  to authenticated
  using (user_id = auth.uid());

create policy "matchmaking_tickets: owner can create"
  on matchmaking_tickets for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "matchmaking_tickets: owner can update"
  on matchmaking_tickets for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "matchmaking_tickets: owner can cancel"
  on matchmaking_tickets for delete
  to authenticated
  using (user_id = auth.uid());

-- =========================================================================
-- Meta-progression — wallets/inventory/battle pass progress are owner-read
-- only; balances change through trusted server logic, not client writes.
-- =========================================================================

create policy "currency_wallets: owner can view"
  on currency_wallets for select
  to authenticated
  using (user_id = auth.uid());

create policy "cosmetic_items: anyone authenticated can view catalog"
  on cosmetic_items for select
  to authenticated
  using (true);

create policy "user_inventory: owner can view"
  on user_inventory for select
  to authenticated
  using (user_id = auth.uid());

create policy "battle_pass_seasons: anyone authenticated can view"
  on battle_pass_seasons for select
  to authenticated
  using (true);

create policy "battle_pass_progress: owner can view"
  on battle_pass_progress for select
  to authenticated
  using (user_id = auth.uid());

-- =========================================================================
-- Social
-- =========================================================================

create policy "friendships: participants can view"
  on friendships for select
  to authenticated
  using (user_id = auth.uid() or friend_id = auth.uid());

create policy "friendships: requester can create"
  on friendships for insert
  to authenticated
  with check (user_id = auth.uid());

create policy "friendships: participants can update"
  on friendships for update
  to authenticated
  using (user_id = auth.uid() or friend_id = auth.uid())
  with check (user_id = auth.uid() or friend_id = auth.uid());

create policy "friendships: participants can delete"
  on friendships for delete
  to authenticated
  using (user_id = auth.uid() or friend_id = auth.uid());

create policy "reports: reporter can view own"
  on reports for select
  to authenticated
  using (reporter_id = auth.uid());

create policy "reports: reporter can file"
  on reports for insert
  to authenticated
  with check (reporter_id = auth.uid());

-- =========================================================================
-- Storage: private bucket for match/training audio
-- =========================================================================

insert into storage.buckets (id, name, public)
values ('voice-recordings', 'voice-recordings', false)
on conflict (id) do nothing;

create policy "voice-recordings: participants can read"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'voice-recordings'
    and (
      (
        (storage.foldername(name))[1] = 'match'
        and exists (
          select 1 from matches m
          where m.id::text = (storage.foldername(name))[2]
            and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
        )
      )
      or (
        (storage.foldername(name))[1] = 'training'
        and exists (
          select 1 from training_sessions ts
          where ts.id::text = (storage.foldername(name))[2]
            and ts.user_id = auth.uid()
        )
      )
    )
  );

create policy "voice-recordings: participants can upload"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'voice-recordings'
    and (
      (
        (storage.foldername(name))[1] = 'match'
        and exists (
          select 1 from matches m
          where m.id::text = (storage.foldername(name))[2]
            and (m.player_a_id = auth.uid() or m.player_b_id = auth.uid())
        )
      )
      or (
        (storage.foldername(name))[1] = 'training'
        and exists (
          select 1 from training_sessions ts
          where ts.id::text = (storage.foldername(name))[2]
            and ts.user_id = auth.uid()
        )
      )
    )
  );
