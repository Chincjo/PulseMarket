-- ===========================================================================
-- PulseMarket — Milestone 19 (assembled by the coordinator from
-- supabase/m19/01-chat-gates.sql, 02-verification.sql,
-- 03-admin-rider-caps.sql and 04-notifications-release.sql).
--
-- DEPLOY ORDER: push the Milestone 19 app code FIRST, then run this
-- file ONCE in the Supabase dashboard (SQL Editor -> New query ->
-- paste this whole file -> Run). The window between the two is safe
-- on purpose: every app change falls back gracefully when these
-- objects do not exist yet (chat gates fail open with the DB as
-- backstop once live, releases use the legacy two-step path,
-- Settings keeps device toggles, the Admin reject picker fails
-- plainly on a reason-less reject).
--
-- NEVER re-run milestone-14/15/16/17/18.sql after this file: this
-- file REPLACES pm_validate_message_insert/_update,
-- pm_validate_pickup_insert/_update, pm_validate_conversation_update,
-- review_verification(), resubmit_verification(),
-- pm_validate_verification_update()/_insert(),
-- pm_validate_order_update() and insert_notification() with the
-- versions below, and re-running an older file would put the old
-- versions back. NEVER re-run milestone-17.sql at all after new
-- signups exist (its grandfather UPDATE would mass-approve every
-- then-pending student without ID review).
--
-- Safe to run twice: every statement is idempotent (ADD COLUMN IF
-- NOT EXISTS, DROP CONSTRAINT / DROP FUNCTION / DROP TRIGGER IF
-- EXISTS, CREATE OR REPLACE, DO blocks that add a CHECK only when
-- it is missing), so re-running it changes nothing.
--
-- WHAT THIS FILE DOES (the owner's approved answers to the 10
-- decisions; decision 10 needed no build):
--   §1  Decision 1 (+4) — later-rejected / flagged students are
--       blocked from NEW messages, offers and pickup tickets in
--       existing chats (app + triggers). Existing orders finish
--       untouched; nothing here reads or writes the orders table.
--       Also adds pm_chat_participant_verified() so the app can show
--       "This seller is no longer verified".
--   §2  Decisions 2 + 3 — pending students can replace ID photos
--       while under review (replace_verification_photos); rejection
--       reasons: rejection_reason / rejection_note columns, and
--       review_verification() now takes a reason (required on
--       reject) plus an optional note.
--   §3  Decisions 5 + 6 + 7 — price caps ₦10,000,000 -> ₦50,000,000
--       (listings + offers, raised not removed); seller-entered
--       rider details for held/shipped Chowdeck Relay orders only.
--       Decision 5 (shipped stuck orders) needs no SQL — the Admin
--       panel wires the existing fetchStaleShippedOrders() helper.
--   §4  Decisions 8 + 9 — server-side notification_prefs table +
--       get/set RPCs, insert_notification() checks the RECIPIENT's
--       prefs; release_order() SECURITY DEFINER RPC writes both
--       ledger legs AND the order status in one transaction.
-- ===========================================================================

-- PulseMarket Milestone 19, section 01 — CHAT GATES (Team A).
--
-- Decision 1 (+4): a student whose verification is LATER rejected
-- (or who becomes flagged) must be blocked from NEW activity in
-- EXISTING conversations, while existing orders finish untouched.
--
-- What this file does:
--   * §0  A shared helper: both participants of a chat must hold an
--         APPROVED, unflagged verifications row.
--   * §1  A small read RPC so a buyer can LEARN whether the seller
--         in their chat is still verified. A student can only read
--         their own verifications row (RLS), so without this the
--         "This seller is no longer verified" note in the chat
--         thread could never be shown. It returns only a boolean
--         per user id, only for users the caller shares a
--         conversation with (or for the team). No new table.
--   * §2  Message INSERT: refuse when either participant is no
--         longer approved or is flagged (covers sendMessage and
--         sendOffer — both insert a message row).
--   * §3  Pickup ticket INSERT: same gate (covers schedulePickup).
--   * §4  Pickup ticket UPDATE: same gate when the spot, date or
--         time changes (a status-only change, e.g. scheduled ->
--         done, still passes — finishing an agreed meetup is not
--         new activity).
--   * §5  Message UPDATE: refuse answering an offer when either
--         side is no longer approved or is flagged (covers
--         respondOffer — the accept path also sets the agreed
--         price, so this is the money-relevant half).
--   * §6  Conversation UPDATE: refuse setting an agreed price when
--         either side is no longer approved or is flagged (the
--         second half of respondOffer — a direct API caller who
--         skips the message update still cannot set the price).
--   * §7  Offer cap: messages_offer_amount_max raised from
--         ₦10,000,000 to ₦50,000,000 (Decision 7), so the database
--         cap matches the app cap. The LISTING price cap
--         (listings_price_max, ₦10,000,000) is NOT changed here.
--
-- What this file does NOT do:
--   * It never touches the orders table. No order is frozen,
--     cancelled or changed when a seller is rejected later — an
--     order already placed runs to completion.
--   * It never re-runs milestones 14–18. Each function below is
--     the live version REPRODUCED with only the gate added:
--     message insert / pickup insert are Milestone 15 verbatim,
--     pickup update is Milestone 16 verbatim, message update is
--     Milestone 18 verbatim, conversation update is Milestone 14
--     verbatim. Re-running any of M14–M18 after this file would
--     put the old, gate-less rules back — never do that.
--   * It does not change pm_is_owner(), the owner email, fees,
--     the 48-hour rule, manual escrow, or any RLS policy.
--
-- Deploy order: run this file AFTER the Milestone 19 app code is
-- pushed (the app calls pm_chat_participant_verified, which does
-- not exist until this file runs — the app fails OPEN without it,
-- so chats keep working and the database triggers below are the
-- backstop once this file is live). Safe to run twice: every
-- statement is idempotent (CREATE OR REPLACE, DROP TRIGGER IF
-- EXISTS, DROP CONSTRAINT guarded by pg_constraint).
--
-- Run AFTER milestones 3–18.

-- ---------------------------------------------------------------------------
-- 0) Shared helper: are BOTH participants of a chat still approved,
--    unflagged students? A missing verifications row counts as NOT
--    verified — the same rule Milestone 17 uses for new chats
--    (pm_validate_conversation_insert requires an approved row for
--    both sides). SECURITY DEFINER so the triggers can read the
--    verifications rows regardless of RLS, like every other
--    pm_validate_* function in milestones 14–18.
-- ---------------------------------------------------------------------------
create or replace function public.pm_chat_verification_ok(p_buyer_id uuid, p_seller_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select
    exists (
      select 1 from public.verifications v
      where v.user_id = p_buyer_id
        and v.status = 'approved'
        and not coalesce(v.flagged, false)
    )
    and
    exists (
      select 1 from public.verifications v
      where v.user_id = p_seller_id
        and v.status = 'approved'
        and not coalesce(v.flagged, false)
    );
$$;

-- ---------------------------------------------------------------------------
-- 1) Read RPC: is each listed student still a verified student?
--    Returns one row per requested id the caller is allowed to ask
--    about — a user the caller shares a conversation with, or any
--    user for the team. Anyone else gets no row back (not an
--    error, and not a "false" that would wrongly paint a stranger
--    as unverified). The app treats a missing row as "unknown"
--    and leaves the chat alone; the triggers below are the real
--    enforcement for a direct API call.
-- ---------------------------------------------------------------------------
create or replace function public.pm_chat_participant_verified(p_user_ids uuid[])
returns table (user_id uuid, is_verified boolean)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in first.';
  end if;
  return query
    select u.id,
      exists (
        select 1 from public.verifications v
        where v.user_id = u.id
          and v.status = 'approved'
          and not coalesce(v.flagged, false)
      )
    from unnest(coalesce(p_user_ids, '{}')) as u(id)
    where public.pm_is_owner()
       or exists (
         select 1 from public.conversations c
         where (c.buyer_id = auth.uid() and c.seller_id = u.id)
            or (c.seller_id = auth.uid() and c.buyer_id = u.id)
       );
end;
$$;

revoke execute on function public.pm_chat_participant_verified(uuid[]) from public;
grant execute on function public.pm_chat_participant_verified(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 2) Message INSERT: Milestone 15 verbatim, plus the verification
--    gate. Covers plain messages AND offers (sendOffer inserts a
--    message row of kind 'offer'), so a direct API caller cannot
--    message or offer in a chat where either side was rejected
--    later or flagged. The gate runs after the participant and
--    blocked checks, so those keep their own plain reasons.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_message_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_other uuid;
  v_buyer uuid;
  v_seller uuid;
begin
  if auth.uid() is null then
    return NEW;
  end if;
  select case when buyer_id = auth.uid() then seller_id else buyer_id end
    into v_other
    from public.conversations
    where id = NEW.conversation_id;
  if v_other is null then
    raise exception 'You are not part of this conversation.';
  end if;
  if exists (
    select 1 from public.blocked_users
    where (blocker_id = auth.uid() and blocked_id = v_other)
       or (blocker_id = v_other and blocked_id = auth.uid())
  ) then
    raise exception 'You cannot message this student.';
  end if;
  -- (M19) Later-rejected / flagged: no new messages in a chat
  -- where either side is no longer an approved, unflagged
  -- student. Existing orders are untouched — this fires only on
  -- INSERT, and nothing here reads or writes the orders table.
  select c.buyer_id, c.seller_id into v_buyer, v_seller
    from public.conversations c
    where c.id = NEW.conversation_id;
  if not public.pm_chat_verification_ok(v_buyer, v_seller) then
    raise exception 'New messages are paused — one of the students in this chat is no longer verified.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_message_insert_trg on public.messages;
create trigger pm_validate_message_insert_trg
  before insert on public.messages
  for each row execute function public.pm_validate_message_insert();

-- ---------------------------------------------------------------------------
-- 3) Pickup ticket INSERT: Milestone 15 verbatim, plus the
--    verification gate (covers schedulePickup). Same placement as
--    the message gate: after the participant and blocked checks.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_pickup_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_other uuid;
  v_buyer uuid;
  v_seller uuid;
  v_d date;
begin
  if auth.uid() is null then
    return NEW;
  end if;
  select case when buyer_id = auth.uid() then seller_id else buyer_id end
    into v_other
    from public.conversations
    where id = NEW.conversation_id;
  if v_other is null then
    raise exception 'You are not part of this conversation.';
  end if;
  if exists (
    select 1 from public.blocked_users
    where (blocker_id = auth.uid() and blocked_id = v_other)
       or (blocker_id = v_other and blocked_id = auth.uid())
  ) then
    raise exception 'You cannot plan a meetup with this student.';
  end if;
  -- (M19) Later-rejected / flagged: no new meetup plans in a chat
  -- where either side is no longer an approved, unflagged student.
  select c.buyer_id, c.seller_id into v_buyer, v_seller
    from public.conversations c
    where c.id = NEW.conversation_id;
  if not public.pm_chat_verification_ok(v_buyer, v_seller) then
    raise exception 'You cannot plan a meetup with this student — one of the students in this chat is no longer verified.';
  end if;
  if NEW.meetup_spot not in (
    'University main gate',
    'Student centre / SUG building',
    'Campus library entrance',
    'Faculty building lobby',
    'Hostel common area (daytime)'
  ) then
    raise exception 'Choose a safe meetup spot from the list.';
  end if;
  if NEW.date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'Pickup date must look like YYYY-MM-DD.';
  end if;
  begin
    v_d := NEW.date::date;
  exception when others then
    raise exception 'Pickup date must be a real calendar date.';
  end;
  if v_d < CURRENT_DATE or v_d > CURRENT_DATE + interval '90 days' then
    raise exception 'Pickup date must be today or within the next 90 days.';
  end if;
  if NEW.time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'Pickup time must look like HH:MM.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_pickup_insert_trg on public.pickup_tickets;
create trigger pm_validate_pickup_insert_trg
  before insert on public.pickup_tickets
  for each row execute function public.pm_validate_pickup_insert();

-- ---------------------------------------------------------------------------
-- 4) Pickup ticket UPDATE: Milestone 16 verbatim, plus the
--    verification gate. The gate runs only when the spot, date or
--    time changes — a status-only change (scheduled -> done) still
--    passes, because finishing an agreed meetup is not new
--    activity. Re-planning a meetup with a later-rejected or
--    flagged student is refused.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_pickup_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_other uuid;
  v_buyer uuid;
  v_seller uuid;
  v_d date;
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.meetup_spot is not distinct from OLD.meetup_spot
    and NEW.date is not distinct from OLD.date
    and NEW.time is not distinct from OLD.time then
    return NEW;
  end if;
  select case when buyer_id = auth.uid() then seller_id else buyer_id end
    into v_other
    from public.conversations
    where id = NEW.conversation_id;
  if v_other is null then
    raise exception 'You are not part of this conversation.';
  end if;
  if exists (
    select 1 from public.blocked_users
    where (blocker_id = auth.uid() and blocked_id = v_other)
       or (blocker_id = v_other and blocked_id = auth.uid())
  ) then
    raise exception 'You cannot plan a meetup with this student.';
  end if;
  -- (M19) Later-rejected / flagged: a meetup cannot be re-planned
  -- in a chat where either side is no longer an approved,
  -- unflagged student.
  select c.buyer_id, c.seller_id into v_buyer, v_seller
    from public.conversations c
    where c.id = NEW.conversation_id;
  if not public.pm_chat_verification_ok(v_buyer, v_seller) then
    raise exception 'You cannot plan a meetup with this student — one of the students in this chat is no longer verified.';
  end if;
  if NEW.meetup_spot not in (
    'University main gate',
    'Student centre / SUG building',
    'Campus library entrance',
    'Faculty building lobby',
    'Hostel common area (daytime)'
  ) then
    raise exception 'Choose a safe meetup spot from the list.';
  end if;
  if NEW.date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
    raise exception 'Pickup date must look like YYYY-MM-DD.';
  end if;
  begin
    v_d := NEW.date::date;
  exception when others then
    raise exception 'Pickup date must be a real calendar date.';
  end;
  if v_d < CURRENT_DATE or v_d > CURRENT_DATE + interval '90 days' then
    raise exception 'Pickup date must be today or within the next 90 days.';
  end if;
  if NEW.time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'Pickup time must look like HH:MM.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_pickup_update_trg on public.pickup_tickets;
create trigger pm_validate_pickup_update_trg
  before update on public.pickup_tickets
  for each row execute function public.pm_validate_pickup_update();

-- ---------------------------------------------------------------------------
-- 5) Message UPDATE: Milestone 18 verbatim, plus the verification
--    gate on answering an offer. Milestone 18 added the blocked
--    check here because the app-side check failed open; the same
--    reasoning applies to verification — the app refuses first
--    (respondOffer), and this is the backstop for a direct API
--    call. Both accept and decline are refused: answering at all
--    is new activity, and accepting also sets the agreed price.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_message_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return NEW;
  end if;
  -- Nothing about a message can be edited — only an offer's status.
  if NEW.id is distinct from OLD.id
    or NEW.conversation_id is distinct from OLD.conversation_id
    or NEW.sender_id is distinct from OLD.sender_id
    or NEW.body is distinct from OLD.body
    or NEW.kind is distinct from OLD.kind
    or NEW.offer_amount is distinct from OLD.offer_amount
    or NEW.created_at is distinct from OLD.created_at
  then
    raise exception 'A message cannot be edited — only an offer can be accepted or declined.';
  end if;
  if NEW.offer_status is distinct from OLD.offer_status then
    if OLD.offer_status <> 'pending'
      or NEW.offer_status not in ('accepted', 'declined') then
      raise exception 'Only a pending offer can be accepted or declined.';
    end if;
    if auth.uid() = OLD.sender_id then
      raise exception 'You cannot accept or decline your own offer.';
    end if;
    if not exists (
      select 1 from public.conversations c
      where c.id = OLD.conversation_id
        and (c.buyer_id = auth.uid() or c.seller_id = auth.uid())
    ) then
      raise exception 'Only a participant of this chat can answer an offer.';
    end if;
    -- (M18) A blocked student cannot answer an offer. The app-side
    -- check was the only guard here and it failed open on a query
    -- error — the database is the backstop now.
    if exists (
      select 1 from public.conversations c
      where c.id = OLD.conversation_id
        and exists (
          select 1 from public.blocked_users b
          where (b.blocker_id = c.buyer_id and b.blocked_id = c.seller_id)
             or (b.blocker_id = c.seller_id and b.blocked_id = c.buyer_id)
        )
    ) then
      raise exception 'You cannot answer an offer in a chat with a blocked student.';
    end if;
    -- (M19) Later-rejected / flagged: an offer cannot be answered
    -- in a chat where either side is no longer an approved,
    -- unflagged student.
    if not exists (
      select 1 from public.conversations c
      where c.id = OLD.conversation_id
        and public.pm_chat_verification_ok(c.buyer_id, c.seller_id)
    ) then
      raise exception 'You cannot answer this offer — one of the students in this chat is no longer verified.';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_message_update_trg on public.messages;
create trigger pm_validate_message_update_trg
  before update on public.messages
  for each row execute function public.pm_validate_message_update();

-- ---------------------------------------------------------------------------
-- 6) Conversation UPDATE: Milestone 14 verbatim, plus the
--    verification gate on setting an agreed price. respondOffer
--    sets agreed_price right after the message update, so the
--    message-update gate above normally stops a bad accept first
--    — this stops a direct API caller who sets the price without
--    an accepted offer (the old check already requires an
--    accepted offer at that amount). Read receipts
--    (buyer/seller_last_read_at) and last_message_at bumps are
--    untouched: the gate only runs when agreed_price changes, so
--    a later-rejected student can still be READ about — the chat
--    history stays visible and existing orders keep moving.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_conversation_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.listing_id is distinct from OLD.listing_id
    or NEW.buyer_id is distinct from OLD.buyer_id
    or NEW.seller_id is distinct from OLD.seller_id
    or NEW.listing_title is distinct from OLD.listing_title
    or NEW.listing_price is distinct from OLD.listing_price
    or NEW.seller_label is distinct from OLD.seller_label
    or NEW.created_at is distinct from OLD.created_at
  then
    raise exception 'A conversation cannot be moved to another listing or person.';
  end if;
  if NEW.agreed_price is distinct from OLD.agreed_price then
    if NEW.agreed_price is null then
      raise exception 'An agreed price cannot be removed.';
    end if;
    if not exists (
      select 1 from public.messages m
      where m.conversation_id = OLD.id
        and m.kind = 'offer'
        and m.offer_status = 'accepted'
        and m.offer_amount = NEW.agreed_price
    ) then
      raise exception 'An agreed price can only be set to an offer the other side accepted.';
    end if;
    -- (M19) Later-rejected / flagged: the agreed price cannot be
    -- set in a chat where either side is no longer an approved,
    -- unflagged student.
    if not public.pm_chat_verification_ok(OLD.buyer_id, OLD.seller_id) then
      raise exception 'An agreed price cannot be set — one of the students in this chat is no longer verified.';
    end if;
  end if;
  if NEW.buyer_last_read_at is distinct from OLD.buyer_last_read_at
    and auth.uid() <> OLD.buyer_id then
    raise exception 'Only the buyer can mark their side read.';
  end if;
  if NEW.seller_last_read_at is distinct from OLD.seller_last_read_at
    and auth.uid() <> OLD.seller_id then
    raise exception 'Only the seller can mark their side read.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_conversation_update_trg on public.conversations;
create trigger pm_validate_conversation_update_trg
  before update on public.conversations
  for each row execute function public.pm_validate_conversation_update();

-- 7) Offer cap: REMOVED in assembly — section 03 §1 raises
--    messages_offer_amount_max (and listings_price_max) to
--    ₦50,000,000. Keeping this block too would drop and
--    re-add the same constraint twice in one run.


-- Done. Milestone 19 section 01 (Team A — chat gates).

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

-- PulseMarket Milestone 19 — Team C section: admin / rider / caps.
--
-- SEPARATE section file assembled by the coordinator into
-- supabase/milestone-19.sql. Do NOT edit milestone-19.sql directly.
--
-- Run ONCE in the Supabase dashboard (SQL Editor -> New query ->
-- paste the assembled milestone-19.sql -> Run), AFTER
-- supabase/milestone-18.sql is confirmed live. Safe to run twice:
-- DROP CONSTRAINT IF EXISTS + ADD CONSTRAINT, and CREATE OR
-- REPLACE + DROP TRIGGER IF EXISTS, so re-running changes nothing.
-- NEVER re-run milestone-14/15/16/17/18.sql after this file:
-- this file REPLACES the order-update trigger from milestone-18,
-- and re-running one of them would put the old team-only rider
-- rule (and the old caps) back.
--
-- What this section does (Milestone 19, Decisions 5/6/7 + Admin
-- follow-ups — app code in src/pages/Admin.jsx,
-- src/pages/Tracking.jsx, src/lib/shipping.js):
--   §1  Decision 7 — price caps ₦10,000,000 -> ₦50,000,000:
--       listings price CHECK + messages offer CHECK. The caps are
--       RAISED, not removed. NOT VALID, like the originals, so old
--       rows never block the migration. Fee math is untouched
--       (the service fee still caps at ₦2,000; only the secure
--       fee keeps growing with price).
--   §2  Decision 6 — rider details: the seller may set
--       rider_name / rider_phone, but ONLY for their own order,
--       ONLY when the courier is Chowdeck Relay and ONLY while
--       the order is held or shipped. Team-entered stays for
--       every other courier / status. The function below is the
--       milestone-18 pm_validate_order_update() copied verbatim
--       EXCEPT section 11 — diff it against milestone-18.sql
--       lines 428-824 to confirm.
--   Decisions 3 + 5 need NO SQL here: Decision 3's
--   review_verification(p_user_id, p_status, p_reason, p_note)
--   is Team B's RPC (this file does not re-implement it), and
--   Decision 5 (stuck shipped orders) is app-only — nudge via
--   the existing insert_notification path, hand-resolve via the
--   existing refund / dispute paths. There is NO auto-confirm
--   anywhere in Milestone 19.
--
-- Run AFTER milestones 3-18.

-- ---------------------------------------------------------------------------
-- §1) Decision 7 — raise the price caps to ₦50,000,000.
--    listings_price_max (milestone-16.sql §20) and
--    messages_offer_amount_max (milestone-15.sql §C).
-- ---------------------------------------------------------------------------
alter table public.listings
  drop constraint if exists listings_price_max;
alter table public.listings
  add constraint listings_price_max check (price <= 50000000) not valid;

alter table public.messages
  drop constraint if exists messages_offer_amount_max;
alter table public.messages
  add constraint messages_offer_amount_max check (offer_amount is null or offer_amount <= 50000000) not valid;

-- ---------------------------------------------------------------------------
-- §2) Decision 6 — seller-entered rider details (Chowdeck Relay only).
--    Full pm_validate_order_update() from milestone-18.sql, with
--    ONLY section 11 changed (see the (M19 Decision 6) note there).
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_order_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_owner boolean := public.pm_is_owner();
  v_is_buyer boolean := v_uid = OLD.buyer_id;
  v_is_seller boolean := v_uid = OLD.seller_id;
  v_via_rpc boolean := coalesce(current_setting('pulsemarket.handoff_rpc', true) = 'true', false);
  v_handoff_ok boolean;
  v_flag_only boolean;
begin
  if v_uid is null then
    return NEW;
  end if;

  -- (a) Money timestamps are stamped here, from the database clock,
  -- not the phone's clock. A caller-supplied value is overwritten.
  if OLD.status = 'reserved' and NEW.status = 'paid' then
    NEW.paid_at := now();
  end if;
  if OLD.status = 'paid' and NEW.status = 'held' then
    NEW.held_at := now();
  end if;
  if OLD.status is distinct from 'delivered' and NEW.status = 'delivered' then
    NEW.delivered_at := now();
  end if;
  if OLD.status is distinct from 'released' and NEW.status = 'released' then
    NEW.released_at := now();
  end if;

  -- 1) Money and identity fields never change after the order is placed.
  if NEW.id is distinct from OLD.id
    or NEW.code is distinct from OLD.code
    or NEW.listing_id is distinct from OLD.listing_id
    or NEW.buyer_id is distinct from OLD.buyer_id
    or NEW.seller_id is distinct from OLD.seller_id
    or NEW.item_price is distinct from OLD.item_price
    or NEW.service_fee is distinct from OLD.service_fee
    or NEW.secure_fee is distinct from OLD.secure_fee
    or NEW.shipping_fee is distinct from OLD.shipping_fee
    or NEW.total is distinct from OLD.total
    or NEW.payment_method is distinct from OLD.payment_method
    or NEW.delivery_method is distinct from OLD.delivery_method
    or NEW.created_at is distinct from OLD.created_at
    or NEW.meetup_spot is distinct from OLD.meetup_spot
    or NEW.ship_to_state is distinct from OLD.ship_to_state
    or NEW.courier is distinct from OLD.courier
  then
    raise exception 'Order details cannot be changed after the order is placed.';
  end if;

  -- The seller code never lives on the order any more (Milestone 14).
  if NEW.seller_code is not null then
    raise exception 'Seller codes are stored in the handoff table, not on the order.';
  end if;

  -- 2) Timestamps only move with the status move they belong to.
  -- (They are stamped above, so a change here means the caller is
  -- trying to move one without its status move.)
  if NEW.paid_at is distinct from OLD.paid_at
    and not (OLD.status = 'reserved' and NEW.status = 'paid') then
    raise exception 'paid_at can only be set when the order is marked paid.';
  end if;
  if NEW.held_at is distinct from OLD.held_at
    and not (OLD.status = 'paid' and NEW.status = 'held') then
    raise exception 'held_at can only be set when the transfer is confirmed.';
  end if;
  if NEW.delivered_at is distinct from OLD.delivered_at
    and not (OLD.status is distinct from 'delivered' and NEW.status = 'delivered') then
    raise exception 'delivered_at can only be set when delivery is confirmed.';
  end if;
  if NEW.released_at is distinct from OLD.released_at
    and not (OLD.status is distinct from 'released' and NEW.status = 'released') then
    raise exception 'released_at can only be set when the money is released.';
  end if;

  -- 3) Frozen money does not move at all until the team resolves the
  -- dispute and unfreezes the order.
  if coalesce(OLD.frozen, false) and NEW.status is distinct from OLD.status then
    raise exception 'This order is frozen — a dispute is open. The PulseMarket team resolves it first.';
  end if;

  -- (DB-15) A return cannot be opened or changed while the order is
  -- frozen — the team resolves the dispute first, then the return.
  -- The unfreeze itself only flips `frozen`, so this never blocks
  -- it. (Handoff confirms are left alone: the status gate above
  -- and the ledger frozen check already stop any money moving.)
  if coalesce(OLD.frozen, false)
    and (NEW.return_status is distinct from OLD.return_status
         or NEW.return_reason is distinct from OLD.return_reason) then
    raise exception 'This order is frozen — a return cannot be opened or changed until the dispute is resolved.';
  end if;

  -- 4) Status moves: only the listed actor may make each move.
  if NEW.status is distinct from OLD.status then
    -- (c) A return that is open stops any release: the money must
    -- stay put until the team resolves the return.
    if NEW.status = 'released' and coalesce(OLD.return_status, '') = 'opened' then
      raise exception 'A return is open for this order — the PulseMarket team resolves it first.';
    end if;

    -- Milestone 17: held -> released is forbidden for EVERYONE,
    -- including the team. Money is only released after delivery is
    -- confirmed (delivered -> released, below). A held order the
    -- seller never ships exits through held -> refunded (team
    -- refund, kept below), never through release — so a buyer can
    -- never release before the item arrives, and the team cannot
    -- do it for them either. Deleting the old branch alone would
    -- have left the generic "cannot move" error; this says why.
    if OLD.status = 'held' and NEW.status = 'released' then
      raise exception 'Money is only released after delivery is confirmed — it cannot be released while the order is still held.';
    end if;

    if OLD.status = 'reserved' and NEW.status = 'paid' and v_is_buyer and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'reserved' and NEW.status = 'delivered' and v_is_buyer and OLD.payment_method = 'cash' then
      null;
    elsif OLD.status = 'reserved' and NEW.status = 'cancelled' and v_is_buyer then
      null;
    elsif OLD.status = 'reserved' and NEW.status = 'cancelled' and v_is_seller then
      -- (M18) The seller may cancel a reserved order the buyer has
      -- ghosted on — the listing goes back to active. Never from
      -- 'paid': the buyer may already have transferred, and only
      -- the team can unwind that.
      null;
    elsif OLD.status = 'paid' and NEW.status = 'held' and v_owner and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'paid' and NEW.status = 'cancelled' and v_is_buyer then
      null;
    elsif OLD.status in ('reserved', 'paid') and NEW.status = 'cancelled' and v_owner then
      -- (M18) The team may cancel a reserved or paid order (a
      -- ghosted buyer, a fraudulent listing). Cancelling a paid
      -- order is a team-only unwind — the transfer is returned by
      -- hand, outside the ledger.
      null;
    elsif OLD.status = 'held' and NEW.status = 'shipped' and v_is_seller and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'held' and NEW.status = 'delivered' and v_is_buyer and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'held' and NEW.status = 'refunded' and v_owner and OLD.payment_method = 'held' then
      -- (F2) Team refund of an order the seller never shipped
      -- (refundHeldOrder, /admin). The refund legs must already
      -- exist — the (b) check below enforces that — and the app
      -- refuses it while a return is open or the order is frozen.
      null;
    elsif OLD.status = 'shipped' and NEW.status = 'delivered' and v_is_buyer and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'shipped' and NEW.status = 'refunded' and v_owner and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'delivered' and NEW.status = 'released'
      and (v_is_buyer or v_owner
           or (v_is_seller and OLD.delivered_at <= now() - interval '48 hours'))
      and OLD.payment_method = 'held' then
      -- The seller branch is the 48h auto-release only: once the
      -- buyer confirmed delivery 48h ago, the release is due
      -- whoever's phone runs the check. A seller can never release
      -- early — that would skip the buyer's return window.
      null;
    elsif OLD.status = 'delivered' and NEW.status = 'refunded' and v_owner and OLD.payment_method = 'held' then
      null;
    else
      raise exception 'Order cannot move from % to %.', OLD.status, NEW.status;
    end if;

    -- Delivery needs the handoff (meet in person) or the verified
    -- unboxing video (shipping). Release of a meet-in-person order
    -- needs the handoff too.
    if NEW.status = 'delivered' or (NEW.status = 'released' and OLD.delivery_method = 'meetup') then
      if OLD.delivery_method = 'meetup' then
        v_handoff_ok := OLD.handoff_scanned_at is not null
          and OLD.handoff_photo_buyer is not null
          and OLD.handoff_photo_seller is not null
          and coalesce(OLD.buyer_confirmed, false)
          and coalesce(OLD.seller_confirmed, false);
        if not v_handoff_ok then
          raise exception 'Handoff not complete — the buyer must scan the seller code and both sides must confirm with photos.';
        end if;
      elsif NEW.status = 'delivered' and OLD.delivery_method = 'shipping' then
        if not public.pm_has_verified_unboxing(OLD.id) then
          raise exception 'Add your unboxing video first — it must be recorded in the app and no longer than 60 seconds.';
        end if;
      end if;
    end if;

    -- (b) The status must have its money behind it already: the
    -- app writes the ledger rows first and then moves the status,
    -- so at this point the rows must exist. A status-only update
    -- (no ledger) used to mark money held / released / refunded
    -- that never moved.
    if OLD.status = 'paid' and NEW.status = 'held' then
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'hold' and bucket = 'held'
      ) then
        raise exception 'No hold is recorded for this order — the money cannot be marked held.';
      end if;
    end if;
    if NEW.status = 'released' then
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'release' and bucket = 'held'
      ) or not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'release' and bucket = 'available'
      ) then
        raise exception 'No release is recorded for this order — the money cannot be marked released.';
      end if;
    end if;
    if NEW.status = 'refunded' then
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'refund' and bucket = 'held'
      ) or not exists (
        select 1 from public.wallet_ledger
        where order_id = OLD.id and kind = 'refund' and bucket = 'available'
      ) then
        raise exception 'No refund is recorded for this order — it cannot be marked refunded.';
      end if;
    end if;

    -- (d) Shipping needs proof: a held order becomes shipped only
    -- with a waybill number, a waybill photo and a delivery PIN.
    if OLD.status = 'held' and NEW.status = 'shipped' then
      if NEW.waybill_number is null or btrim(NEW.waybill_number) = ''
        or NEW.waybill_photo is null
        or NEW.delivery_pin is null then
        raise exception 'Shipping proof needs a waybill number, a waybill photo and a delivery PIN.';
      end if;
    end if;
  end if;

  -- 5) Handoff scan / attempts / lock: only the server-side code
  -- check (verify_seller_code) or the team may write these. A buyer
  -- typing the code into a direct API call cannot mark their own
  -- handoff scanned.
  if NEW.handoff_scanned_at is distinct from OLD.handoff_scanned_at
    or NEW.code_attempts is distinct from OLD.code_attempts
    or NEW.handoff_locked is distinct from OLD.handoff_locked
  then
    if not (v_via_rpc or v_owner) then
      raise exception 'The seller code can only be checked through the handoff scan.';
    end if;
  end if;

  -- 6) Frozen flag: the buyer may freeze (file a dispute); only the
  -- team may unfreeze (resolve it).
  if NEW.frozen is distinct from OLD.frozen then
    if v_owner then
      null;
    elsif v_is_buyer and NEW.frozen = true and coalesce(OLD.frozen, false) = false then
      null;
    else
      raise exception 'Only the PulseMarket team can change the frozen flag.';
    end if;
  end if;

  -- 7) Handoff photos: each side sets only its own, and it must be a
  -- file they uploaded to their own folder in the evidence bucket
  -- (the URL pattern the app's own uploads produce). (e) A photo is
  -- frozen once that side has confirmed — the evidence cannot be
  -- swapped after the handoff is agreed.
  if NEW.handoff_photo_buyer is distinct from OLD.handoff_photo_buyer then
    if not v_is_buyer then
      raise exception 'Only the buyer can set the buyer handoff photo.';
    end if;
    if coalesce(OLD.buyer_confirmed, false) then
      raise exception 'The buyer handoff photo cannot be changed after the buyer confirmed.';
    end if;
    if NEW.handoff_photo_buyer is not null
      and NEW.handoff_photo_buyer not like '%/storage/v1/object/public/evidence-media/' || v_uid::text || '/%' then
      raise exception 'The handoff photo must be a photo uploaded from this app.';
    end if;
  end if;
  if NEW.handoff_photo_seller is distinct from OLD.handoff_photo_seller then
    if not v_is_seller then
      raise exception 'Only the seller can set the seller handoff photo.';
    end if;
    if coalesce(OLD.seller_confirmed, false) then
      raise exception 'The seller handoff photo cannot be changed after the seller confirmed.';
    end if;
    if NEW.handoff_photo_seller is not null
      and NEW.handoff_photo_seller not like '%/storage/v1/object/public/evidence-media/' || v_uid::text || '/%' then
      raise exception 'The handoff photo must be a photo uploaded from this app.';
    end if;
  end if;

  -- 8) Dual confirm: only your own flag, only after the scan and
  -- your own photo, and never un-confirming.
  if NEW.buyer_confirmed is distinct from OLD.buyer_confirmed then
    if not v_is_buyer or NEW.buyer_confirmed is not true
      or OLD.handoff_scanned_at is null or OLD.handoff_photo_buyer is null then
      raise exception 'Only the buyer can confirm, after scanning the code and taking the handoff photo.';
    end if;
  end if;
  if NEW.seller_confirmed is distinct from OLD.seller_confirmed then
    if not v_is_seller or NEW.seller_confirmed is not true
      or OLD.handoff_scanned_at is null or OLD.handoff_photo_seller is null then
      raise exception 'Only the seller can confirm, after the code is scanned and taking the handoff photo.';
    end if;
  end if;

  -- 9) Shipping proof: seller only, only with the held -> shipped move.
  -- (f) One exception: setting ONLY the shipping_advance_released
  -- flag, on a shipped/delivered order whose proof is complete and
  -- whose advance is already in the ledger — the retry step in
  -- submitShippingProof, after the advance was paid but the flag
  -- update was lost.
  if NEW.delivery_pin is distinct from OLD.delivery_pin
    or NEW.waybill_number is distinct from OLD.waybill_number
    or NEW.waybill_photo is distinct from OLD.waybill_photo
    or NEW.receipt_photo is distinct from OLD.receipt_photo
    or NEW.driver_phone is distinct from OLD.driver_phone
    or NEW.shipping_proof_at is distinct from OLD.shipping_proof_at
    or NEW.shipping_advance_released is distinct from OLD.shipping_advance_released
  then
    v_flag_only :=
      NEW.delivery_pin is not distinct from OLD.delivery_pin
      and NEW.waybill_number is not distinct from OLD.waybill_number
      and NEW.waybill_photo is not distinct from OLD.waybill_photo
      and NEW.receipt_photo is not distinct from OLD.receipt_photo
      and NEW.driver_phone is not distinct from OLD.driver_phone
      and NEW.shipping_proof_at is not distinct from OLD.shipping_proof_at
      and NEW.shipping_advance_released is distinct from OLD.shipping_advance_released;
    if v_flag_only then
      if not (v_is_seller and NEW.shipping_advance_released = true
              and OLD.status in ('shipped', 'delivered') and NEW.status = OLD.status
              and OLD.waybill_number is not null and OLD.receipt_photo is not null
              and OLD.courier in ('GIG Logistics', 'GUO Transport', 'DHL Domestic', 'Peace Logistics', 'ABC Transport')
              and exists (
                select 1 from public.wallet_ledger
                where order_id = OLD.id and kind = 'shipping_advance'
                  and bucket = 'available' and amount > 0
              )) then
        raise exception 'The shipping advance flag can only be set once the advance is in the ledger.';
      end if;
    else
      if not (v_is_seller and OLD.status = 'held' and NEW.status = 'shipped') then
        raise exception 'Shipping proof can only be submitted by the seller when the money is held.';
      end if;
      if NEW.delivery_pin is not null and NEW.delivery_pin !~ '^[0-9]{6}$' then
        raise exception 'The delivery PIN must be 6 digits.';
      end if;
      if NEW.waybill_number is not null and btrim(NEW.waybill_number) = '' then
        raise exception 'The waybill number cannot be empty.';
      end if;
      if NEW.waybill_photo is not null
        and NEW.waybill_photo not like '%/storage/v1/object/public/evidence-media/' || v_uid::text || '/%' then
        raise exception 'The waybill photo must be a photo uploaded from this app.';
      end if;
      if NEW.receipt_photo is not null
        and NEW.receipt_photo not like '%/storage/v1/object/public/evidence-media/' || v_uid::text || '/%' then
        raise exception 'The receipt photo must be a photo uploaded from this app.';
      end if;
    end if;
  end if;

  -- 10) Returns: the buyer opens (after shipping), the team resolves.
  if NEW.return_status is distinct from OLD.return_status then
    if NEW.return_status = 'opened' then
      if not v_is_buyer or OLD.status not in ('shipped', 'delivered') then
        raise exception 'A return can only be opened by the buyer after the item has shipped.';
      end if;
    elsif NEW.return_status = 'resolved' then
      if not v_owner or OLD.return_status <> 'opened' then
        raise exception 'Only the PulseMarket team can resolve an open return.';
      end if;
    else
      raise exception 'Unknown return status.';
    end if;
  end if;
  if NEW.return_reason is distinct from OLD.return_reason then
    if not (v_is_buyer and NEW.return_status = 'opened'
            and OLD.return_status is distinct from 'opened') then
      raise exception 'The return reason can only be set when the return is opened.';
    end if;
  end if;

  -- 11) Rider details (M19 Decision 6 — ONLY this section differs
  -- from milestone-18.sql). The team may set them any time, as
  -- before. The SELLER may also set them, but ONLY for their own
  -- order, ONLY when the courier is Chowdeck Relay (same-city) and
  -- ONLY while the order is held or shipped — the exact case the
  -- seller rider form in src/pages/Tracking.jsx writes through
  -- src/lib/shipping.js updateRiderDetails(). Every other courier,
  -- status or actor is still team-only, and a rider edit may not
  -- smuggle a status change with it.
  if (NEW.rider_name is distinct from OLD.rider_name
      or NEW.rider_phone is distinct from OLD.rider_phone) then
    if v_owner then
      null;
    elsif v_is_seller
      and OLD.courier = 'Chowdeck Relay'
      and OLD.status in ('held', 'shipped')
      and NEW.status = OLD.status
    then
      if NEW.rider_name is not null and btrim(NEW.rider_name) = '' then
        raise exception 'The rider name cannot be empty.';
      end if;
      if NEW.rider_phone is not null
        and NEW.rider_phone !~ '^\+?[0-9][0-9 ()-]{6,14}$' then
        raise exception 'That rider phone number does not look right.';
      end if;
    else
      raise exception 'Only the PulseMarket team can set rider details, except the seller for a held or shipped Chowdeck Relay order.';
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_order_update_trg on public.orders;
create trigger pm_validate_order_update_trg
  before update on public.orders
  for each row execute function public.pm_validate_order_update();

-- PulseMarket Milestone 19, section 4 — Server-side notification
-- prefs + server-side release RPC.
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: every statement
-- below is idempotent (CREATE TABLE / ADD COLUMN IF NOT EXISTS,
-- DROP POLICY IF EXISTS, CREATE OR REPLACE), so re-running it changes
-- nothing and never deletes a row.
--
-- Run AFTER milestones 3–18. NEVER re-run milestone-14/15/16/17/18
-- after this file: this file REPLACES insert_notification() with a
-- version that adds the prefs check, and re-running an older file
-- would put the old version back (no prefs check).
--
-- DEPLOY ORDER: push the Milestone 19 app code first, then run this
-- file. The window between the two is safe on purpose: the app
-- falls back gracefully when these objects do not exist yet —
-- releaseOrder() uses its old app-side two-step release, and
-- Settings keeps the device-only toggles until the server prefs
-- load. Once this file has run, the RPC paths take over.
--
-- WHAT THIS FILE DOES
--   Decision 8 — server-side notification prefs:
--     * notification_prefs: one row per student, one toggle per
--       notification kind the app sends (the 8 kinds in
--       src/lib/notifications.js NOTIFICATION_KINDS). No row means
--       everything on — a student who never touched Settings gets
--       every notification, exactly as today.
--     * get_notification_prefs() / set_notification_prefs(): the
--       app reads/writes the CALLER's own prefs only. Neither
--       function takes a user id at all, so a caller can never
--       read or change another student's prefs.
--     * insert_notification() is replaced (Milestone 15's version,
--       reproduced here with ONE change): after the participant
--       check passes, it looks up the RECIPIENT's prefs and, when
--       the recipient turned that kind off, returns null silently
--       — no row is written, no error is raised, and no rate-limit
--       quota is spent. Everything else (participant check, length
--       caps, 120/hour rate limit, sender_id) is byte-for-byte
--       Milestone 15.
--   Decision 9 — server-side release RPC:
--     * release_order(p_order_id): writes both ledger legs AND the
--       order status update in ONE transaction, so the half-move
--       window the app-side two-step left open (money moved, status
--       update lost) is gone. Every gate the app-side release
--       enforced is re-checked explicitly inside this function
--       (see the header note below on auth.uid()).
--
-- ---------------------------------------------------------------------------
-- AUTH.UID() INSIDE SECURITY DEFINER — WHAT WAS VERIFIED (read-only:
-- there is no Postgres in this VM, so this was verified by reading
-- the live Milestone 10–18 code, not by running it)
-- ---------------------------------------------------------------------------
-- A SECURITY DEFINER function runs with the privileges of its owner,
-- but auth.uid() / auth.jwt() do NOT return the owner: they read the
-- caller's JWT claims, which PostgREST sets per request
-- (request.jwt.claims) and which a change of execution role does not
-- touch. Evidence inside this repo:
--   * insert_notification() (M10/M14/M15) is SECURITY DEFINER and
--     its participant check is `auth.uid() = buyer/seller` — if
--     auth.uid() returned the function owner, no cross-user
--     notification would ever be delivered. They are delivered live.
--   * pm_validate_ledger_insert() (M14–M17) is a SECURITY DEFINER
--     trigger function and its release branch requires
--     `auth.uid() = buyer OR pm_is_owner() OR (seller after 48h)` —
--     if it saw the owner, every app-side ledger write would be
--     refused. confirmReceipt / releaseOrder work live.
--   * pm_is_owner() reads `auth.jwt() ->> 'email'`; the owner flows
--     (confirm receipt, admin refund) work live, so auth.jwt()
--     inside SECURITY DEFINER still carries the caller's email.
-- So inside release_order(), auth.uid() is the caller and
-- pm_is_owner() is the caller-is-team check, exactly as in the
-- triggers. BELT AND BRACES ANYWAY: release_order() captures
-- v_caller := auth.uid() ONCE at the top and does EVERY actor and
-- gate check explicitly in its own body, before it touches the
-- ledger or the order — it never relies on the triggers alone.
-- If the triggers ever saw a different identity, the RPC's own
-- checks would still be the gate; the triggers can only re-check
-- the same rules (and both triggers step aside entirely when
-- auth.uid() is null, so a null identity cannot wrongly block a
-- move the RPC already allowed).
-- Trigger behaviour the RPC was written against (M17/M18, read):
--   * pm_validate_order_update: delivered -> released only for
--     buyer / team / seller-after-48h; held -> released forbidden
--     for everyone; frozen blocks any status move; an open return
--     blocks release; a meet-in-person release needs the handoff
--     complete; the status move to 'released' requires BOTH
--     release legs to already exist; released_at is stamped here
--     from the database clock.
--   * pm_validate_ledger_insert: a release needs the money held
--     first; the held leg must be exactly -(total - advance) and
--     the available leg exactly item_price + shipping_fee -
--     advance; the available leg needs the held leg first; the
--     held sum can never go below zero (backstop against draining
--     the same hold twice); the order row is locked FOR UPDATE.
-- The RPC mirrors all of it: it locks the order row first, checks
-- the actor and gates itself, inserts the held leg before the
-- available leg with the exact trigger amounts, and only then
-- moves the status — in the same transaction.
--
-- KNOWN GAP (not fixed here, for the coordinator): the pg_cron
-- auto-release function auto_release_overdue_orders() (M10)
-- inserts its 'release' notifications DIRECTLY into the
-- notifications table, not through insert_notification(), so those
-- two rows do not pass the prefs check. pg_cron is not set up, so
-- nothing sends through that path today; if it ever is, that
-- function needs the same prefs check on its direct inserts.

-- ---------------------------------------------------------------------------
-- 1) notification_prefs — one row per student, one toggle per kind.
--    Column names are <kind>_enabled so the mapping from the
--    notification kind is mechanical. All default true: no row, or
--    a row that never touched a toggle, means everything on.
-- ---------------------------------------------------------------------------
create table if not exists public.notification_prefs (
  user_id uuid primary key references auth.users (id) on delete cascade,
  order_enabled boolean not null default true,
  message_enabled boolean not null default true,
  checkpoint_enabled boolean not null default true,
  dispute_enabled boolean not null default true,
  rating_enabled boolean not null default true,
  boost_enabled boolean not null default true,
  release_enabled boolean not null default true,
  system_enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.notification_prefs enable row level security;

-- A student reads only their own prefs row. (The RPCs below are
-- SECURITY DEFINER and bypass RLS; these policies protect direct
-- table access through the API.)
drop policy if exists "Users read their own notification prefs" on public.notification_prefs;
create policy "Users read their own notification prefs"
  on public.notification_prefs for select
  using (auth.uid() = user_id);

drop policy if exists "Users insert their own notification prefs" on public.notification_prefs;
create policy "Users insert their own notification prefs"
  on public.notification_prefs for insert
  with check (auth.uid() = user_id);

drop policy if exists "Users update their own notification prefs" on public.notification_prefs;
create policy "Users update their own notification prefs"
  on public.notification_prefs for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Nobody deletes prefs (no delete policy). Turning everything off
-- is the way to silence notifications, not deleting the row.

-- ---------------------------------------------------------------------------
-- 2) get_notification_prefs() — read the CALLER's own prefs.
--    Returns a row of all-true defaults when the caller has never
--    saved prefs (no row is written — reading settings must not
--    create data). Takes no user id, so nobody can read anyone
--    else's prefs.
-- ---------------------------------------------------------------------------
create or replace function public.get_notification_prefs()
returns public.notification_prefs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.notification_prefs;
begin
  if auth.uid() is null then
    raise exception 'Sign in to read your notification settings.';
  end if;

  select * into v_row
  from public.notification_prefs
  where user_id = auth.uid();

  if not found then
    v_row.user_id := auth.uid();
    v_row.order_enabled := true;
    v_row.message_enabled := true;
    v_row.checkpoint_enabled := true;
    v_row.dispute_enabled := true;
    v_row.rating_enabled := true;
    v_row.boost_enabled := true;
    v_row.release_enabled := true;
    v_row.system_enabled := true;
    v_row.updated_at := now();
  end if;

  return v_row;
end;
$$;

revoke execute on function public.get_notification_prefs() from public;
grant execute on function public.get_notification_prefs() to authenticated;

-- ---------------------------------------------------------------------------
-- 3) set_notification_prefs() — write the CALLER's own prefs.
--    One boolean per kind; a null argument means "leave that toggle
--    alone", so the app can save a single toggle without sending
--    the other seven. The row is upserted: the first save creates
--    it (missing toggles default true), later saves change only
--    the toggles passed. user_id is always auth.uid() — the caller
--    can never write another student's row. Returns the saved row.
-- ---------------------------------------------------------------------------
create or replace function public.set_notification_prefs(
  p_order boolean default null,
  p_message boolean default null,
  p_checkpoint boolean default null,
  p_dispute boolean default null,
  p_rating boolean default null,
  p_boost boolean default null,
  p_release boolean default null,
  p_system boolean default null
)
returns public.notification_prefs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.notification_prefs;
begin
  if auth.uid() is null then
    raise exception 'Sign in to change your notification settings.';
  end if;

  insert into public.notification_prefs as np
    (user_id, order_enabled, message_enabled, checkpoint_enabled,
     dispute_enabled, rating_enabled, boost_enabled, release_enabled,
     system_enabled)
  values
    (auth.uid(),
     coalesce(p_order, true), coalesce(p_message, true),
     coalesce(p_checkpoint, true), coalesce(p_dispute, true),
     coalesce(p_rating, true), coalesce(p_boost, true),
     coalesce(p_release, true), coalesce(p_system, true))
  on conflict (user_id) do update set
    order_enabled = coalesce(p_order, np.order_enabled),
    message_enabled = coalesce(p_message, np.message_enabled),
    checkpoint_enabled = coalesce(p_checkpoint, np.checkpoint_enabled),
    dispute_enabled = coalesce(p_dispute, np.dispute_enabled),
    rating_enabled = coalesce(p_rating, np.rating_enabled),
    boost_enabled = coalesce(p_boost, np.boost_enabled),
    release_enabled = coalesce(p_release, np.release_enabled),
    system_enabled = coalesce(p_system, np.system_enabled),
    updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

revoke execute on function public.set_notification_prefs(boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean) from public;
grant execute on function public.set_notification_prefs(boolean, boolean, boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) insert_notification() — Milestone 15's version, with ONE
--    change (the M19 prefs gate, marked below). Everything else is
--    reproduced byte-for-byte from supabase/milestone-15.sql
--    section D, so no earlier protection is lost:
--      (a) self-notify always allowed;
--      (b)/(c) an order/conversation participant may notify ONLY
--        the other party to that order/conversation;
--      (d) the PulseMarket team account may notify anyone;
--      length caps (title 200, body 500, link 500);
--      (e) rate limit: at most 120 notifications per caller per
--        hour, counted by sender_id.
--    The prefs gate sits AFTER the participant check and BEFORE
--    the rate limit, on purpose: a stranger probing a user they
--    may not notify still gets 'not allowed' (never a silent
--    null that would reveal the recipient's settings), and a
--    notification the recipient switched off never burns quota.
-- ---------------------------------------------------------------------------
-- sender_id was added by Milestone 15; kept here so this section
-- stands alone if it is ever run on a database that missed it.
alter table public.notifications
  add column if not exists sender_id uuid references auth.users (id) on delete set null;

create or replace function public.insert_notification(
  p_user_id uuid,
  p_kind text,
  p_title text,
  p_body text default null,
  p_link text default null,
  p_order_id uuid default null,
  p_conversation_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_allowed boolean := false;
  v_kind_on boolean;
begin
  if p_user_id is null then
    raise exception 'notification needs a recipient';
  end if;
  if p_kind not in ('order', 'message', 'checkpoint', 'dispute', 'rating', 'boost', 'release', 'system') then
    raise exception 'unknown notification kind %', p_kind;
  end if;
  if p_title is null or btrim(p_title) = '' then
    raise exception 'notification needs a title';
  end if;
  if char_length(btrim(p_title)) > 200 then
    raise exception 'notification title too long';
  end if;
  if p_body is not null and char_length(p_body) > 500 then
    raise exception 'notification body too long';
  end if;
  if p_link is not null and char_length(p_link) > 500 then
    raise exception 'notification link too long';
  end if;

  -- (a) notifying yourself is always allowed.
  if auth.uid() = p_user_id then
    v_allowed := true;
  end if;

  -- (b) a participant of the order may notify ONLY the other party
  -- to that order — not any user they pick.
  if not v_allowed and p_order_id is not null then
    select exists (
      select 1 from public.orders
      where id = p_order_id
        and ((buyer_id = auth.uid() and seller_id = p_user_id)
             or (seller_id = auth.uid() and buyer_id = p_user_id))
    ) into v_allowed;
  end if;

  -- (c) a participant of the conversation may notify ONLY the other
  -- party to that conversation.
  if not v_allowed and p_conversation_id is not null then
    select exists (
      select 1 from public.conversations
      where id = p_conversation_id
        and ((buyer_id = auth.uid() and seller_id = p_user_id)
             or (seller_id = auth.uid() and buyer_id = p_user_id))
    ) into v_allowed;
  end if;

  -- (d) the PulseMarket team account may notify anyone.
  if not v_allowed and (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com' then
    v_allowed := true;
  end if;

  if not v_allowed then
    raise exception 'not allowed to notify this user';
  end if;

  -- (M19) RECIPIENT'S PREFS ARE THE REAL GATE. If the recipient
  -- turned this kind off, the notification is silently dropped:
  -- return null, raise nothing, write nothing. No prefs row means
  -- everything on (defaults), so students who never touched
  -- Settings keep getting every notification, exactly as today.
  select case p_kind
    when 'order' then order_enabled
    when 'message' then message_enabled
    when 'checkpoint' then checkpoint_enabled
    when 'dispute' then dispute_enabled
    when 'rating' then rating_enabled
    when 'boost' then boost_enabled
    when 'release' then release_enabled
    when 'system' then system_enabled
  end into v_kind_on
  from public.notification_prefs
  where user_id = p_user_id;

  if found and coalesce(v_kind_on, true) = false then
    return null;
  end if;

  -- (e) rate limit: at most 120 notifications per caller per hour.
  if (select count(*) from public.notifications
      where sender_id = auth.uid()
        and created_at > now() - interval '1 hour') >= 120 then
    raise exception 'Too many notifications — try again later.';
  end if;

  insert into public.notifications (user_id, kind, title, body, link, sender_id)
  values (p_user_id, p_kind, btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), nullif(btrim(coalesce(p_link, '')), ''), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.insert_notification(uuid, text, text, text, text, uuid, uuid) from public;
grant execute on function public.insert_notification(uuid, text, text, text, text, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) release_order(p_order_id) — Decision 9. One transaction that
--    writes both ledger legs AND the order status update, so the
--    half-move window is gone: either the money and the status move
--    together, or neither does.
--
--    Who may call it: the buyer (any time after delivery), the
--    PulseMarket team (any time after delivery), or the seller once
--    48 hours have passed since delivery (the auto-release branch).
--    Everyone else — including a seller before 48h — is refused.
--
--    Gates, all checked explicitly in this body (see the
--    auth.uid() note at the top of this file — the triggers
--    re-check the same rules, but this function never relies on
--    them alone):
--      * order exists (row locked FOR UPDATE first, so two
--        concurrent releases queue here instead of racing);
--      * held order only — cash orders never hold money;
--      * status must be 'delivered' (a held order cannot release;
--        any other status has no held money to release);
--      * not frozen (open dispute) and no return open;
--      * meet-in-person orders need the handoff complete;
--      * release amount = total minus any shipping advance already
--        paid, on BOTH legs, re-derived from the order (same math
--        as M10 auto_release_overdue_orders() and the app-side
--        release): held leg -(total - advance), available leg
--        item_price + shipping_fee - advance.
--
--    Idempotent: when the release legs already exist (a pre-M19
--    half-move, or a retried call), the money is NOT moved again —
--    the missing leg, if any, is written and the order is closed
--    out. When the order is already 'released' with both legs,
--    the order is returned as-is. The unique index
--    wallet_ledger_one_release_idx is the backstop.
--
--    What this function does NOT do (the app still does it):
--      * flip the listing to 'sold' — the app does that best
--        effort after the call returns, as before;
--      * send the 'release' notifications — the app sends them
--        through notifyUser() after the call returns, so they pass
--        the recipient's prefs check in section 4.
-- ---------------------------------------------------------------------------
create or replace function public.release_order(p_order_id uuid)
returns public.orders
language plpgsql
security definer
set search_path = public
as $$
declare
  -- Captured ONCE, up front: every check below uses v_caller (and
  -- pm_is_owner(), which reads the caller's JWT email), never a
  -- re-read after a trigger could have run.
  v_caller uuid := auth.uid();
  v_order public.orders%rowtype;
  v_advance integer := 0;
  v_held_out integer;
  v_avail_in integer;
  v_has_held_leg boolean := false;
  v_has_avail_leg boolean := false;
begin
  if p_order_id is null then
    raise exception 'A release needs an order.';
  end if;
  if v_caller is null then
    raise exception 'Sign in to release this order.';
  end if;

  -- Lock the order row first: concurrent releases queue here, and
  -- the sums below are read after the lock (same pattern as the
  -- ledger trigger and auto_release_overdue_orders()).
  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found.';
  end if;

  if v_order.payment_method <> 'held' then
    raise exception 'Cash orders are settled face to face — there is no held money to release.';
  end if;

  -- Which release legs, if any, are already written? Read now so
  -- the idempotency branches below and the inserts both use the
  -- same picture.
  select exists (
    select 1 from public.wallet_ledger
    where order_id = v_order.id and kind = 'release' and bucket = 'held'
  ) into v_has_held_leg;

  select exists (
    select 1 from public.wallet_ledger
    where order_id = v_order.id and kind = 'release' and bucket = 'available'
  ) into v_has_avail_leg;

  -- Already released, money already moved: return the order
  -- as-is, never pay twice. (A 'released' order with NO release
  -- legs cannot exist — the order-update trigger refuses it — so
  -- one that is ever found is refused loudly instead of papered
  -- over.)
  if v_order.status = 'released' then
    if v_has_held_leg and v_has_avail_leg then
      return v_order;
    end if;
    raise exception 'This order was already released — the money moved once.';
  end if;

  -- Milestone 17: release opens only after delivery is confirmed.
  if v_order.status = 'held' then
    raise exception 'The money is still held — release opens once delivery is confirmed. Confirm delivery first, then release the money to the seller.';
  end if;
  if v_order.status <> 'delivered' then
    raise exception 'This order is % — there is no held money to release.', v_order.status;
  end if;

  -- Milestone 12: a frozen order (open dispute) cannot release
  -- until the team resolves it.
  if coalesce(v_order.frozen, false) then
    raise exception 'This order is frozen — a dispute is open. The PulseMarket team resolves it first.';
  end if;

  -- A return that is open stops any release: the money must stay
  -- put until the team resolves the return.
  if coalesce(v_order.return_status, '') = 'opened' then
    raise exception 'A return is open for this order — the PulseMarket team resolves it first.';
  end if;

  -- A refund already drained the hold (a return was resolved, or
  -- the team refunded a held order): there is nothing left to
  -- release. This cannot happen for a 'delivered' order through
  -- the app — resolving a return always moves the order to
  -- 'refunded' — but a direct API write could leave the rows
  -- behind, so refuse in plain words instead of letting the
  -- ledger trigger's held-sum backstop refuse it cryptically.
  if exists (
    select 1 from public.wallet_ledger
    where order_id = v_order.id and kind = 'refund' and bucket = 'held'
  ) then
    raise exception 'This order was already refunded — there is no held money to release.';
  end if;

  -- Actor: buyer any time; team any time; seller only once 48h
  -- have passed since delivery (the auto-release branch — a
  -- seller releasing early would skip the buyer's return window).
  if not (v_caller = v_order.buyer_id
          or public.pm_is_owner()
          or (v_caller = v_order.seller_id
              and v_order.delivered_at is not null
              and v_order.delivered_at <= now() - interval '48 hours')) then
    if v_caller = v_order.seller_id then
      raise exception 'The seller can only release 48 hours after delivery — the buyer still has time to check the item.';
    end if;
    raise exception 'Only the buyer or the PulseMarket team can release this order.';
  end if;

  -- Milestone 7: a meet-in-person order releases only after the
  -- handoff is complete — code scanned, both photos, both sides
  -- confirmed. (Shipping orders were gated on the verified
  -- unboxing video at delivery, not at release — same as the
  -- order-update trigger, which checks the handoff only for a
  -- meet-in-person release.)
  if v_order.delivery_method = 'meetup' then
    if not (v_order.handoff_scanned_at is not null
            and v_order.handoff_photo_buyer is not null
            and v_order.handoff_photo_seller is not null
            and coalesce(v_order.buyer_confirmed, false)
            and coalesce(v_order.seller_confirmed, false)) then
      raise exception 'Handoff not complete — the buyer must scan the seller code and both sides must confirm with photos.';
    end if;
  end if;

  -- Money math, re-derived from the order: the shipping advance
  -- already paid is subtracted from both legs so the seller is
  -- never paid the same money twice. An advance can never exceed
  -- the shipping fee (the ledger trigger's held-sum backstop
  -- refuses it), so total - advance stays positive for any real
  -- order; a negative value here means corrupt data, so refuse
  -- instead of writing a nonsense leg.
  select coalesce(sum(amount), 0) into v_advance
  from public.wallet_ledger
  where order_id = v_order.id
    and kind = 'shipping_advance'
    and bucket = 'available';

  v_held_out := v_order.total - v_advance;
  v_avail_in := v_order.item_price + v_order.shipping_fee - v_advance;

  if v_held_out < 0 then
    raise exception 'There is nothing left held for this order — the advance already covered it.';
  end if;
  if v_avail_in < 0 then
    raise exception 'There is nothing left to release for this order.';
  end if;

  -- Ledger legs first, held leg before available leg (the ledger
  -- trigger requires the held leg to exist before the available
  -- leg). Each leg is skipped when it already exists, so a retried
  -- call or a pre-M19 half-move never pays twice. created_by is
  -- the buyer, matching the app-side release and M10's
  -- auto-release.
  if not v_has_held_leg then
    insert into public.wallet_ledger
      (order_id, user_id, bucket, kind, amount, note, created_by)
    values
      (v_order.id, v_order.seller_id, 'held', 'release', -v_held_out,
       'Released from hold for order ' || v_order.code, v_order.buyer_id);
  end if;

  if not v_has_avail_leg then
    insert into public.wallet_ledger
      (order_id, user_id, bucket, kind, amount, note, created_by)
    values
      (v_order.id, v_order.seller_id, 'available', 'release', v_avail_in,
       'Released to seller for order ' || v_order.code, v_order.buyer_id);
  end if;

  -- Status second, in the SAME transaction: either the money and
  -- the status move together, or neither does. The order-update
  -- trigger re-checks the same gates and stamps released_at from
  -- the database clock, so only the status is set here.
  update public.orders
  set status = 'released',
      updated_at = now()
  where id = v_order.id
  returning * into v_order;

  return v_order;
end;
$$;

revoke execute on function public.release_order(uuid) from public;
grant execute on function public.release_order(uuid) to authenticated;

-- Done. Milestone 19 section 4 (notification prefs + release RPC).
