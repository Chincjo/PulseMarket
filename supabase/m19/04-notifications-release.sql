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
