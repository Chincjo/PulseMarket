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

-- ---------------------------------------------------------------------------
-- 7) Offer cap (Decision 7): ₦10,000,000 -> ₦50,000,000, matching
--    the app cap (MAX_OFFER_NAIRA in src/lib/chat.js). Milestone
--    15 added this as NOT VALID so no legacy row can fail the
--    migration; dropping and re-adding keeps that property (the
--    check is never validated against old rows).
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from pg_constraint where conname = 'messages_offer_amount_max'
  ) then
    alter table public.messages drop constraint messages_offer_amount_max;
  end if;
  alter table public.messages
    add constraint messages_offer_amount_max
    check (offer_amount is null or offer_amount <= 50000000) not valid;
end $$;

-- Done. Milestone 19 section 01 (Team A — chat gates).
