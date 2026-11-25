-- PulseMarket Milestone 19, section 02 — verification photos and
-- rejection reasons (Team B: Decisions 2, 3 and 7-app cap is code
-- only — MAX_LISTING_PRICE in src/lib/listings.js, no SQL here).
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query
-- -> paste this whole file -> Run. Safe to run twice: every
-- statement below is idempotent (ADD COLUMN IF NOT EXISTS, DO blocks
-- that add a CHECK only when it is missing, CREATE OR REPLACE,
-- DROP TRIGGER / DROP FUNCTION IF EXISTS), so re-running it changes
-- nothing.
--
-- Run AFTER milestones 3–18 are live (M18 fully live 2026-11-25).
-- NEVER re-run milestone-14/15/16/17.sql after this file: they
-- would put the old verification gates back. This file REPLACES
-- their review_verification(), resubmit_verification() and
-- pm_validate_verification_update() / _insert() with the versions
-- below — every reproduced line is identical to milestone-18.sql
-- except for the changes marked "(M19)".
--
-- WHAT THIS FILE DOES:
--   * Decision 2 — a student whose verification is still 'pending
--     review' can replace their own ID photos while waiting:
--     replace_verification_photos() (§4), same own-folder +
--     object-must-exist checks as M18 §3 resubmit. Status stays
--     'pending review'. The review queue position resets: the row
--     carries a new updated_at (§1–§2) and the admin list orders
--     by updated_at, so a student who just replaced their photos
--     goes to the back of the queue and the team reviews the
--     newest photos.
--   * Decision 3 — rejection reasons: rejection_reason and
--     rejection_note columns (§1). review_verification() (§3) now
--     takes a reason and an optional note; rejecting WITHOUT a
--     reason FAILS. Approving clears any earlier reason/note;
--     resubmitting / replacing clears them too, so a stale reason
--     is never shown for a fresh review.
--   * The update trigger (§6) now lets the resubmit flag through
--     for BOTH rejected -> pending review (resubmit) and pending
--     review -> pending review (replace), and refuses any other
--     change to the rejection reason/note — only the team RPC may
--     set them.
--
-- WHAT THIS FILE DOES NOT CHANGE: pm_is_owner() and the owner
-- email, the fee rules, the 48-hour rule, manual escrow, the
-- identity lock, the held -> released ban, the verification-ids
-- bucket and its storage policies (M17), or any other table.

-- ---------------------------------------------------------------------------
-- 1) Columns on verifications.
--    * rejection_reason — one of the fixed list, null unless the
--      student was rejected. The list is enforced by a CHECK, so a
--      typo or a new reason can never be stored.
--    * rejection_note — the team's optional short note to the
--      student, capped at 280 characters.
--    * updated_at — last time the row changed. There was NO
--      updated_at on this table before (only created_at), so it is
--      added here; existing rows get the migration time as their
--      first value and the trigger in §2 keeps it fresh after that.
--      The admin pending list orders by updated_at, then created_at
--      (ties among pre-M19 rows fall back to submission order).
--    No CHECK ties 'rejected' to a non-null reason at table level:
--    students rejected before M19 have no reason stored, and a
--    table CHECK would refuse to be added over those rows. The
--    reject-needs-a-reason rule lives in review_verification()
--    (§3) instead — every rejection goes through that RPC.
-- ---------------------------------------------------------------------------
alter table public.verifications
  add column if not exists rejection_reason text;
alter table public.verifications
  add column if not exists rejection_note text;
alter table public.verifications
  add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'verifications_rejection_reason_check'
      and conrelid = 'public.verifications'::regclass
  ) then
    alter table public.verifications
      add constraint verifications_rejection_reason_check
      check (rejection_reason is null
        or rejection_reason in ('blurry', 'wrong document', 'name mismatch', 'expired', 'other'));
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'verifications_rejection_note_check'
      and conrelid = 'public.verifications'::regclass
  ) then
    alter table public.verifications
      add constraint verifications_rejection_note_check
      check (rejection_note is null or char_length(rejection_note) <= 280);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2) Stamp updated_at on every update. A plain BEFORE UPDATE
--    trigger: the row's own update trigger (§6) does not touch
--    updated_at, and no app code writes it — the database owns it,
--    so a crafted call cannot fake a queue position.
-- ---------------------------------------------------------------------------
create or replace function public.pm_verifications_set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  NEW.updated_at := now();
  return NEW;
end;
$$;

drop trigger if exists pm_verifications_updated_at_trg on public.verifications;
create trigger pm_verifications_updated_at_trg
  before update on public.verifications
  for each row execute function public.pm_verifications_set_updated_at();

-- ---------------------------------------------------------------------------
-- 3) review_verification: rejection now needs a reason (M19).
--    New signature: review_verification(p_user_id, p_status,
--    p_reason, p_note). p_reason and p_note default to null so an
--    old two-argument call still resolves — but a REJECT with no
--    (or an unknown) reason FAILS, and a note over 280 characters
--    FAILS. Approving clears any earlier reason and note.
--    The old two-argument function is DROPPED first: without that,
--    Postgres would keep both overloads and a two-argument reject
--    could silently call the old version with no reason at all.
-- ---------------------------------------------------------------------------
drop function if exists public.review_verification(uuid, text);

create or replace function public.review_verification(p_user_id uuid, p_status text, p_reason text default null, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.pm_is_owner() then
    raise exception 'Only the PulseMarket team can review verifications.';
  end if;
  if p_status not in ('approved', 'rejected') then
    raise exception 'A verification can only be approved or rejected.';
  end if;
  if p_user_id is null then
    raise exception 'A verification needs a student.';
  end if;
  -- (M19) A rejection without a reason fails — the student must be
  -- told what to fix. The fixed list matches the column CHECK in
  -- §1 and VERIFICATION_REJECTION_REASONS in src/lib/listings.js.
  if p_status = 'rejected' then
    if p_reason is null
      or p_reason not in ('blurry', 'wrong document', 'name mismatch', 'expired', 'other') then
      raise exception 'A rejection needs a reason: blurry, wrong document, name mismatch, expired or other.';
    end if;
    if v_note is not null and char_length(v_note) > 280 then
      raise exception 'Keep the note to the student under 280 characters.';
    end if;
  end if;
  -- (M18) Approval needs ID photos to review. Grandfathered rows
  -- are already approved, so they never pass through here again;
  -- a photo-less row must resubmit with photos first.
  if p_status = 'approved' then
    if not exists (
      select 1 from public.verifications
      where user_id = p_user_id
        and nullif(btrim(id_front_url), '') is not null
        and nullif(btrim(id_back_url), '') is not null
    ) then
      raise exception 'That student has no ID photos to review — ask them to submit photos first.';
    end if;
  end if;
  update public.verifications
    set status = p_status,
        -- (M19) An approval carries no reason or note; a rejection
        -- carries exactly the reason and note given. Either way the
        -- row never keeps a reason from an earlier decision.
        rejection_reason = case when p_status = 'rejected' then p_reason else null end,
        rejection_note = case when p_status = 'rejected' then v_note else null end
    where user_id = p_user_id;
  if not found then
    raise exception 'That student has no verification to review.';
  end if;
end;
$$;

revoke execute on function public.review_verification(uuid, text, text, text) from public;
grant execute on function public.review_verification(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) replace_verification_photos: Decision 2. A student whose
--    verification is still 'pending review' swaps both ID photos
--    for new ones. Status stays 'pending review' — nothing else
--    moves — and updated_at (§2) stamps the change, so the admin
--    queue (ordered by updated_at) puts this student at the back
--    and the team reviews the newest photos. Any earlier rejection
--    reason/note is cleared (a pending row should not carry one).
--    The photo checks are the M18 §3 resubmit checks verbatim:
--    bare storage paths ('<uid>/front-<ms>.jpg', never public
--    URLs — see src/lib/listings.js), in the caller's own folder,
--    and the object must actually exist in the private bucket.
--    The same transaction flag as resubmit lets the update trigger
--    (§6) recognise this as the one allowed photo change.
-- ---------------------------------------------------------------------------
create or replace function public.replace_verification_photos(p_front_url text, p_back_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first to replace your ID photos.';
  end if;
  if p_front_url is null or btrim(p_front_url) = ''
    or p_back_url is null or btrim(p_back_url) = '' then
    raise exception 'Add photos of the front and back of your student ID.';
  end if;
  if p_front_url = p_back_url then
    raise exception 'The front and back photos must be different files.';
  end if;
  if split_part(p_front_url, '?', 1) not like auth.uid()::text || '/%'
    or split_part(p_back_url, '?', 1) not like auth.uid()::text || '/%'
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_front_url, '?', 1)
    )
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_back_url, '?', 1)
    ) then
    raise exception 'The ID photos must be photos you uploaded from this app.';
  end if;
  select status into v_status
    from public.verifications
    where user_id = auth.uid();
  if not found then
    raise exception 'You have no verification to update — submit it first.';
  end if;
  if v_status <> 'pending review' then
    raise exception 'You can only replace your ID photos while your verification is still under review.';
  end if;
  -- Transaction-local flag (gone at commit) that the update trigger
  -- in section 6 recognises. Set it here, inside the RPC, and
  -- nowhere else: the app cannot set it through PostgREST.
  perform set_config('pulsemarket.verification_resubmit', 'true', true);
  update public.verifications
    set status = 'pending review',
        id_front_url = p_front_url,
        id_back_url = p_back_url,
        rejection_reason = null,
        rejection_note = null
    where user_id = auth.uid();
end;
$$;

revoke execute on function public.replace_verification_photos(text, text) from public;
grant execute on function public.replace_verification_photos(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) resubmit_verification: same function, same signature, one
--    (M19) change — a resubmit clears the rejection reason and
--    note, so the student waiting again is not shown the old
--    reason for a review that has not happened yet. Everything
--    else is the M18 §3 version verbatim (bare-path + own-folder +
--    object-exists checks, rejected-only).
-- ---------------------------------------------------------------------------
create or replace function public.resubmit_verification(p_front_url text, p_back_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first to resubmit your verification.';
  end if;
  if p_front_url is null or btrim(p_front_url) = ''
    or p_back_url is null or btrim(p_back_url) = '' then
    raise exception 'Add photos of the front and back of your student ID.';
  end if;
  if p_front_url = p_back_url then
    raise exception 'The front and back photos must be different files.';
  end if;
  -- (M18) CRITICAL FIX: the app stores BARE storage paths
  -- ('<uid>/front-<ms>.jpg'), never public URLs — see
  -- src/lib/listings.js. M17's '%verification-ids/<uid>/%' pattern
  -- could never match a bare path, so EVERY resubmit was refused
  -- and a rejected student could never resubmit. The path must
  -- start with the caller's own uid folder, and the object must
  -- actually exist in the private bucket.
  if split_part(p_front_url, '?', 1) not like auth.uid()::text || '/%'
    or split_part(p_back_url, '?', 1) not like auth.uid()::text || '/%'
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_front_url, '?', 1)
    )
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(p_back_url, '?', 1)
    ) then
    raise exception 'The ID photos must be photos you uploaded from this app.';
  end if;
  select status into v_status
    from public.verifications
    where user_id = auth.uid();
  if not found then
    raise exception 'You have no verification to resubmit — submit it first.';
  end if;
  if v_status <> 'rejected' then
    raise exception 'Only a rejected verification can be resubmitted.';
  end if;
  -- Transaction-local flag (gone at commit) that the update trigger
  -- in section 6 recognises. Set it here, inside the RPC, and
  -- nowhere else: the app cannot set it through PostgREST.
  perform set_config('pulsemarket.verification_resubmit', 'true', true);
  update public.verifications
    set status = 'pending review',
        id_front_url = p_front_url,
        id_back_url = p_back_url,
        -- (M19) A resubmit clears the rejection reason and note.
        rejection_reason = null,
        rejection_note = null
    where user_id = auth.uid();
end;
$$;

revoke execute on function public.resubmit_verification(text, text) from public;
grant execute on function public.resubmit_verification(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6) Verification updates: lock photo URLs outside resubmit/replace
--    (H3) and lock the rejection reason/note to the team (M19).
--    This REPLACES the M18 §4 function. Every line is identical
--    except the (M19) marks:
--      * the resubmit branch now allows BOTH rejected -> 'pending
--        review' (resubmit_verification, §5) and 'pending review'
--        -> 'pending review' (replace_verification_photos, §4),
--        and requires the reason/note to end up null there;
--      * outside that branch, a change to rejection_reason or
--        rejection_note is refused — only the team RPC (§3) sets
--        them (the team bypasses this trigger at the top, as
--        before, via pm_is_owner()).
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_verification_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_resubmit boolean := coalesce(current_setting('pulsemarket.verification_resubmit', true) = 'true', false);
begin
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
  end if;
  -- Milestone 17 resubmit path: resubmit_verification() sets the
  -- transaction flag 'pulsemarket.verification_resubmit' (the same
  -- pattern as the handoff flag the flagged check below
  -- recognises), and the RPC itself already checked the caller is
  -- the row owner and the row is 'rejected'. Only exactly rejected
  -- -> 'pending review' may pass here, and only with new ID
  -- photos — every other column is still locked, so university /
  -- student ID / student email / invite code / referral /
  -- chat_verified_only cannot move on a resubmit.
  -- (M19) replace_verification_photos() sets the same flag, and
  -- its RPC already checked the row is 'pending review', so the
  -- branch also allows 'pending review' -> 'pending review' with
  -- new photos — and nothing else. Both RPCs clear the rejection
  -- reason/note, so they must end up null here.
  if v_resubmit then
    if auth.uid() <> OLD.user_id then
      raise exception 'Only the student can resubmit their own verification.';
    end if;
    if OLD.status not in ('rejected', 'pending review') or NEW.status <> 'pending review' then
      raise exception 'A resubmission can only move a rejected or waiting verification back to pending review.';
    end if;
    if NEW.flagged is distinct from OLD.flagged
      or NEW.university is distinct from OLD.university
      or NEW.student_id is distinct from OLD.student_id
      or NEW.student_email is distinct from OLD.student_email
      or NEW.invite_code is distinct from OLD.invite_code
      or NEW.referred_by is distinct from OLD.referred_by
      or NEW.chat_verified_only is distinct from OLD.chat_verified_only
      or NEW.user_id is distinct from OLD.user_id then
      raise exception 'A resubmission can only update the ID photos.';
    end if;
    if NEW.id_front_url is null or btrim(NEW.id_front_url) = ''
      or NEW.id_back_url is null or btrim(NEW.id_back_url) = ''
      or NEW.id_front_url = NEW.id_back_url then
      raise exception 'A resubmission needs photos of the front and back of your student ID.';
    end if;
    if split_part(NEW.id_front_url, '?', 1) not like auth.uid()::text || '/%'
      or split_part(NEW.id_back_url, '?', 1) not like auth.uid()::text || '/%' then
      raise exception 'The ID photos must be photos you uploaded from this app.';
    end if;
    -- (M19) A resubmit / replace clears the earlier rejection
    -- reason and note — it must never smuggle a new one in.
    if NEW.rejection_reason is not null or NEW.rejection_note is not null then
      raise exception 'A resubmission clears the earlier rejection reason.';
    end if;
    return NEW;
  end if;
  -- (M18) ID photos can only change through resubmit_verification()
  -- (the branch above, which returns early). A direct update that
  -- swaps the photo URLs is refused — otherwise the resubmit RPC's
  -- own-folder check means nothing.
  -- (M19) Same for replace_verification_photos(): the branch above
  -- is the only way photos change.
  if NEW.id_front_url is distinct from OLD.id_front_url
    or NEW.id_back_url is distinct from OLD.id_back_url then
    raise exception 'ID photos can only be changed by resubmitting your verification or replacing them while under review.';
  end if;
  -- (M19) The rejection reason and note are set only by the team
  -- review RPC (§3). A student writing them directly — e.g. to
  -- fake a rejection, or to wipe a real one — is refused.
  if NEW.rejection_reason is distinct from OLD.rejection_reason
    or NEW.rejection_note is distinct from OLD.rejection_note then
    raise exception 'Only the PulseMarket team can set a rejection reason.';
  end if;
  if NEW.status is distinct from OLD.status then
    raise exception 'Only the PulseMarket team can change a verification status.';
  end if;
  if NEW.flagged is distinct from OLD.flagged
    and not coalesce(current_setting('pulsemarket.handoff_rpc', true) = 'true', false) then
    raise exception 'Only the PulseMarket team can flag an account.';
  end if;
  if NEW.university is distinct from OLD.university
    or NEW.student_id is distinct from OLD.student_id
    or NEW.student_email is distinct from OLD.student_email
  then
    raise exception 'University, student ID and student email cannot be changed after verification is submitted.';
  end if;
  -- (DB-9) Invite codes may be backfilled exactly once: rows created
  -- before invite codes existed have invite_code NULL, and
  -- getOrCreateInviteCode() fills it in. Any other change is refused.
  if NEW.invite_code is distinct from OLD.invite_code
    and OLD.invite_code is not null
  then
    raise exception 'Invite code cannot be changed after verification is submitted.';
  end if;
  if NEW.referred_by is distinct from OLD.referred_by then
    if OLD.referred_by is not null then
      raise exception 'A referral cannot be changed once recorded.';
    end if;
    if NEW.referred_by = NEW.invite_code then
      raise exception 'You cannot refer yourself.';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_verification_update_trg on public.verifications;
create trigger pm_validate_verification_update_trg
  before update on public.verifications
  for each row execute function public.pm_validate_verification_update();

-- ---------------------------------------------------------------------------
-- 7) Verification inserts: new rows must carry both ID photos (H3)
--    and no rejection reason (M19). This REPLACES the M18 §5
--    function; the only change is the (M19) check at the end.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_verification_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
  end if;
  if NEW.status is distinct from 'pending review' then
    raise exception 'New verifications always start as pending review.';
  end if;
  if coalesce(NEW.flagged, false) then
    raise exception 'A new verification is never flagged.';
  end if;
  if NEW.referred_by is not null and NEW.invite_code is not null
    and NEW.referred_by = NEW.invite_code then
    raise exception 'You cannot refer yourself.';
  end if;
  -- (M18) A verification row must carry both ID photos, in the
  -- caller's own folder (bare storage paths, e.g.
  -- '<uid>/front-<ms>.jpg' — see src/lib/listings.js). The team
  -- reviews whatever is stored here, so a photo-less or fake-URL
  -- row must never be created.
  if NEW.id_front_url is null or btrim(NEW.id_front_url) = ''
    or NEW.id_back_url is null or btrim(NEW.id_back_url) = '' then
    raise exception 'Add photos of the front and back of your student ID.';
  end if;
  if NEW.id_front_url = NEW.id_back_url then
    raise exception 'The front and back photos must be different files.';
  end if;
  if split_part(NEW.id_front_url, '?', 1) not like auth.uid()::text || '/%'
    or split_part(NEW.id_back_url, '?', 1) not like auth.uid()::text || '/%' then
    raise exception 'The ID photos must be photos you uploaded from this app.';
  end if;
  -- (M19) A new verification has no rejection reason or note — a
  -- rejection only ever comes from the team review (§3).
  if NEW.rejection_reason is not null or NEW.rejection_note is not null then
    raise exception 'A new verification has no rejection reason.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_verification_insert_trg on public.verifications;
create trigger pm_validate_verification_insert_trg
  before insert on public.verifications
  for each row execute function public.pm_validate_verification_insert();

-- Done. Milestone 19, section 02 (verification photos + rejection reasons).
