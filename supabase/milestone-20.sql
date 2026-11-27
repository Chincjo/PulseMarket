-- ===========================================================================
-- PulseMarket — Milestone 20 (nightly + morning deep checks, 2026-11-25/26).
--
-- DEPLOY ORDER: push the Milestone 20 app code FIRST, then run this
-- file ONCE in the Supabase SQL Editor. NEVER re-run
-- milestone-14/15/16/17/18/19.sql after it (the functions below
-- REPLACE the live versions; re-running an older file would put the
-- old rules back). NEVER re-run milestone-17.sql as-is (its
-- grandfather UPDATE mass-approves pending students — it is
-- commented out in the repo copy; never restore it). Safe to run
-- this file twice: every statement is idempotent.
--
-- WHAT RICHARD DECIDED (2026-11-26, "Yes, build it this way"):
--   D-1  Chats with an open order keep allowing PLAIN text messages
--        so buyer and seller can coordinate delivery. Offers, offer
--        answers, pickup tickets and agreed prices stay BLOCKED for
--        later-rejected students.
--   D-2  'dispute' notifications and team 'system' notifications
--        bypass notification prefs — they always get through.
--   D-3  A seller-fault return refunds the FULL total, fees
--        included — the buyer loses nothing when the seller is at
--        fault. A TEAM refund with no return open is DIFFERENT:
--        the buyer gets item + shipping back and the fees stay
--        with PulseMarket (owner decision 2026-11-26).
--   D-4  Reservation expiry is an APP-side sweep (cancel 'reserved'
--        orders older than 48h, free the listing, notify both
--        parties). No SQL was needed for it.
--
-- CONTENTS — assembled from supabase/m20/01-core.sql (night items
-- SQL-1..SQL-14, §12 patch specs, D-1/D-2/D-3, M-1, M-3, M-4, M-7,
-- M-8, M-10, M-13, M-16, M-22, M-23, M-24, M-25) and
-- supabase/m20/02-hardening.sql (M-2 boost, M-6 evidence bucket,
-- M-9 handoff bytes, M-11 listing values, M-12 checkpoints, M-14,
-- M-15, M-17, M-19, M-20, M-21). Every reproduced function was
-- diff-verified against its cited source; only the documented
-- change differs. Keep the section files as the source of truth —
-- if this file ever needs a fix, fix the section file and
-- re-assemble.
--
-- CODE-FIRST WINDOW (safe by design, like M19): new app code falls
-- back to legacy paths while the new RPCs do not exist yet
-- (respond_offer, purchase_boost — PGRST202/42883 only). The
-- agreed-price checkout path needs M-23 in the same release
-- window (the old order-insert trigger refuses an agreed price).
-- Push code, then run this file immediately after.
--
-- KNOWN GAPS (not fixed here, by design or by decision):
--   M-5  Evidence "verified" still trusts caller-supplied
--        duration_seconds via direct API (the app measures it and
--        throws when it cannot; the DB cannot measure a video).
--        Needs server-side media inspection (Edge Function) — the
--        team spot-checks unboxing videos before release.
--   Delivery PIN readable by a determined direct-API caller (the
--        app strips it; a buyer-only PIN table needs Richard's
--        decision — not built).
--   bump_listing_view() is ready but the app does not call it yet.
--
-- Done. Milestone 20 — assembled 2026-11-26, NOT run, NOT pushed.
-- ===========================================================================

-- ===========================================================================
-- PulseMarket — Milestone 20, CORE SQL (supabase/m20/01-core.sql).
--
-- DEPLOY ORDER: push the Milestone 20 app code FIRST, then run this
-- file ONCE in the Supabase SQL Editor. NEVER re-run
-- milestone-14/15/16/17/18/19.sql after it (each function below
-- REPLACES the live version; re-running an older file would put the
-- old rules back). NEVER re-run milestone-17.sql as-is (its
-- grandfather UPDATE mass-approves pending students). Safe to run
-- this file twice: every statement is idempotent (CREATE OR REPLACE,
-- DROP TRIGGER IF EXISTS, CREATE UNIQUE INDEX IF NOT EXISTS, DROP
-- POLICY IF EXISTS).
--
-- WHAT RICHARD DECIDED (2026-11-26, "Yes, build it this way"):
--   D-1  Chats with an open order keep allowing PLAIN text messages
--        so buyer and seller can coordinate delivery. Offers, offer
--        answers, pickup tickets and agreed prices stay BLOCKED for
--        later-rejected students. (See pm_validate_message_insert.)
--   D-2  'dispute' notifications and team 'system' notifications
--        bypass notification prefs — they always get through.
--        (See insert_notification.)
--   D-3  A seller-fault return refunds the FULL total, fees
--        included — the buyer loses nothing when the seller is at
--        fault. A TEAM refund with no return open is DIFFERENT:
--        the buyer gets item + shipping back and the fees stay
--        with PulseMarket (owner decision 2026-11-26). (See the
--        M-1 note in pm_validate_ledger_insert.)
--   D-4  Reservation expiry is an APP-side sweep (cancel reserved
--        orders older than 48h). No SQL was needed for it: the
--        order-update trigger already lets the buyer AND the seller
--        cancel a 'reserved' order, and nothing in this file
--        changes that — verified, not assumed.
--
-- READ BEFORE YOU RUN — FOUR PLACES WHERE THIS FILE DELIBERATELY
-- DIFFERS FROM THE NIGHT DRAFT (milestone-20-draft.sql), BECAUSE
-- DIFF-CHECKING THE DRAFT AGAINST THE LIVE SOURCES PROVED THE DRAFT
-- WRONG THERE. EACH IS MARKED AGAIN AT THE SITE:
--   (1) Draft §3 (listing status allowlist) is NOT carried over
--       verbatim. Its premise — "no listing-UPDATE trigger" — is
--       wrong: milestone-16.sql already has pm_validate_listing_update
--       (boost tier/expiry checks, identity-field locks, the
--       open-order freeze on photos/title/price/delivery, the
--       view-count path). Replacing it with the draft's short
--       function would have DELETED all of that. Instead the live
--       M16 function is reproduced whole and the allowlist is added
--       on top. Also 'delisted' is NOT in the allowlist: the
--       listings table CHECK (milestone-3-4.sql) only allows
--       active / reserved / sold, so a 'delisted' status can never
--       be stored — the draft's delisted transitions could never fire.
--   (2) Draft §5 (auto-release) is based on milestone-10.sql, but
--       the LIVE auto-release is milestone-12.sql, which adds a
--       frozen guard (a disputed order never auto-releases). The
--       draft's version drops that guard. This file bases the
--       merged §5+M-4 function on M12, keeping the frozen guard.
--   (3) The order-insert trigger and the ledger trigger are
--       reproduced from milestone-17.sql, NOT milestone-16.sql as
--       the draft cites — M17 is the live version (M17 only changed
--       the order-insert verification wording to require status
--       'approved', and the ledger release wording to require
--       delivery first; both changes are kept here).
--   (4) Draft §12-(B) (team corrects the return-fault label "at
--       resolution") is WIDENED — see note B-2 below. As written,
--       the draft only allows the correction in the same UPDATE
--       that resolves the return; but the ledger refuses refund
--       legs once a return is resolved, so legs written after that
--       update would fail and legs written before it would still
--       be priced from the OLD label. The correction must be
--       allowed while the return is still open, BEFORE the legs.
--
-- NOTE B-2 — resolveReturn WRITE ORDER (read this before changing
-- src/lib/shipping.js): the team corrects a wrong fault label with
-- its OWN order update FIRST (return still 'opened', reason
-- corrected), THEN the refund legs are written (the ledger prices
-- them from the stored reason at insert time), THEN the resolving
-- update (status 'refunded', return_status 'resolved'). Any other
-- order prices the refund from the wrong label or refuses the legs.
--
-- NOTE D-3 / M-1 — THE REFUND LEGS (the money must balance):
--   Seller-fault return (D-3: FULL total):
--     refund held leg (seller) ...... -(total - advance)
--     refund available leg (buyer) .. +total (FULL total, fees in)
--     seller debt leg (seller) ...... -advance (kind 'debt', only
--       when advance > 0; skipped otherwise)
--   Team refund with no return open (owner decision 2026-11-26:
--   team refunds KEEP the fee):
--     refund held leg (seller) ...... -(total - advance)
--     refund available leg (buyer) .. +(item_price + shipping_fee)
--     seller debt leg (seller) ...... -advance (kind 'debt', only
--       when advance > 0; skipped otherwise)
--   Buyer-fault return:
--     refund held leg (seller) ...... -(total - advance)
--     refund available leg (buyer) .. +item_price
--     release available leg (seller)  +(shipping_fee - advance)
--       (only when shipping_fee - advance > 0)
--   Worked example — 5,000 item + 3,500 shipping + 425 fees =
--   8,925 held, advance 1,750 (half the shipping fee, already
--   with the seller):
--     Seller fault: held +8,925 -1,750 -7,175 = 0. Buyer
--     +8,925 (the FULL total). Seller +1,750 -1,750 = 0.
--     In = 8,925, out = 8,925. Nothing created, nothing lost.
--     Team refund: held +8,925 -1,750 -7,175 = 0. Buyer
--     +8,500 (item + shipping). Seller +1,750 -1,750 = 0.
--     In = 8,925, out = 8,500 + 425 kept by PulseMarket as
--     the fee = 8,925. Nothing created, nothing lost.
--     (The OLD amounts also paid the buyer 8,500 — but the
--     seller KEPT the 1,750 advance with no debt recorded, so
--     8,500 + 1,750 = 10,250 out of 8,925 held: 1,325 created.
--     The debt leg is what fixes it, not the buyer amount.)
--     Buyer fault: held +8,925 -1,750 -7,175 = 0. Buyer
--     +5,000 (item only). Seller +1,750 (advance kept) +1,750
--     (remaining shipping) = +3,500. In = 8,925, out =
--     5,000 + 3,500 + 425 kept by PulseMarket as the fee = 8,925.
--     The buyer loses the 425 fee + the 1,750 advance, as before.
--   WHY THE LEGS LOOK LIKE THIS: the draft's four-leg sketch
--   (buyer +(total-advance) AND buyer +advance as two refund rows,
--   plus a seller -advance refund row) CANNOT be written — the
--   wallet_ledger_one_refund_idx unique index (milestone-14.sql)
--   allows exactly ONE 'refund' row per (order, bucket), so a
--   second buyer refund row and a seller refund row in the same
--   bucket are refused with a unique violation. The +advance is
--   therefore folded into the buyer's +total leg and the clawback
--   rides on the existing 'debt' kind (one debt per order, §2
--   index) — the net money movement is identical to the sketch.
--   APP COUPLING — the coordinator reconciles the app legs to this
--   spec in the same release: resolveReturn (seller fault) must
--   send buyer +total and record the debt when advance > 0 (it
--   already records the debt); refundHeldOrder (team refund) must
--   send buyer +(item_price + shipping_fee) — the fees stay with
--   PulseMarket — must be allowed for shipped/delivered orders
--   (today the app refuses anything but 'held'), and must record
--   the debt when advance > 0 (today it never does).
--   Until the app and this SQL ship together, refunds use the OLD
--   amounts — code first, then this SQL, in the same window.
--
-- NOTE D-2 / M-16 — WHO SENDS 'release' NOTICES: neither the
-- release_order RPC nor auto-release calls insert_notification()
-- with kind 'release'. The app sends the notice through
-- notifyUser() AFTER release_order returns (finishRelease in
-- src/lib/orders.js), as the buyer/team, with the order id and a
-- '/order/<uuid>' link — so the release legs already exist by
-- then, and the M-16 leg check below lets it through. Auto-release
-- writes its notices straight to the notifications table.
--
-- NOT IN THIS FILE (other workers / not built): end-to-end
-- encryption, IP blocking, a buyer-only PIN table, draft §12-(G)
-- open questions, M-2 free boost, M-5/M-6 evidence bucket, M-9
-- handoff storage policy, M-11 listing values, M-12 checkpoints,
-- M-14/M-15 oracles, M-17 dispute checks, M-18 listing flips,
-- M-19 view count, M-20 security_log, M-21 invite codes,
-- pm_validate_listing_insert (values),
-- pm_has_verified_unboxing, count_referrals, security_log
-- triggers, invite-code index, view-count, storage policies,
-- boost functions.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- §1 + §2 — verification oracle revoked; one seller debt per order (draft verbatim).
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- §1) SQL-4 — the verification oracle: pm_chat_verification_ok() was
-- created with default PUBLIC execute and takes arbitrary UUIDs.
-- Triggers call it as SECURITY DEFINER, so they need no grant.
-- ---------------------------------------------------------------------------
revoke execute on function public.pm_chat_verification_ok(uuid, uuid) from public;

-- ---------------------------------------------------------------------------
-- §2) SQL-5 — one seller debt per order. recordSellerDebt() inserts
-- unconditionally; the other money kinds already have one-* indexes
-- (M14) and this closes the same hole for debts. If this fails, a
-- duplicate debt row already exists — find and fix it first, then
-- re-run this statement.
-- ---------------------------------------------------------------------------
create unique index if not exists wallet_ledger_one_debt_idx
  on public.wallet_ledger (order_id) where kind = 'debt';

-- ---------------------------------------------------------------------------
-- §3 — SQL-13 listing status allowlist. Milestone-16's live pm_validate_listing_update(), reproduced whole, with ONLY the allowlist added (see file header, difference (1)).
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_listing_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return NEW;
  end if;

  -- (0) A view count may only ever go up by exactly one, by anyone.
  if NEW.views = OLD.views + 1
    and NEW.id is not distinct from OLD.id
    and NEW.seller_id is not distinct from OLD.seller_id
    and NEW.seller_label is not distinct from OLD.seller_label
    and NEW.title is not distinct from OLD.title
    and NEW.description is not distinct from OLD.description
    and NEW.price is not distinct from OLD.price
    and NEW.condition is not distinct from OLD.condition
    and NEW.category is not distinct from OLD.category
    and NEW.university is not distinct from OLD.university
    and NEW.state is not distinct from OLD.state
    and NEW.ships_to is not distinct from OLD.ships_to
    and NEW.delivery_methods is not distinct from OLD.delivery_methods
    and NEW.courier is not distinct from OLD.courier
    and NEW.meetup_spot is not distinct from OLD.meetup_spot
    and NEW.photos is not distinct from OLD.photos
    and NEW.boost_tier is not distinct from OLD.boost_tier
    and NEW.boosted_until is not distinct from OLD.boosted_until
    and NEW.created_at is not distinct from OLD.created_at
    and NEW.status is not distinct from OLD.status
  then
    return NEW;
  end if;

  if auth.uid() = OLD.seller_id or public.pm_is_owner() then
    if NEW.id is distinct from OLD.id
      or NEW.seller_id is distinct from OLD.seller_id
      or NEW.seller_label is distinct from OLD.seller_label
      or NEW.university is distinct from OLD.university
      or NEW.state is distinct from OLD.state
      or NEW.views is distinct from OLD.views
      or NEW.created_at is distinct from OLD.created_at
    then
      raise exception 'A listing''s seller, university, state and view count cannot be changed.';
    end if;
    if NEW.status not in ('active', 'reserved', 'sold') then
      raise exception 'A listing status can only be active, reserved or sold.';
    end if;
    -- (M20 SQL-13) Status moves follow the allowlist: 'sold' is
    -- terminal; an active listing can only be reserved; a reserved
    -- listing can only go back to active or be marked sold. The
    -- team bypasses this so a bad state can always be fixed by
    -- hand. ('delisted' is not a storable status — the listings
    -- table CHECK only allows active / reserved / sold — so no
    -- delisted transition is listed here.) This only fires when the
    -- status actually moves, so ordinary edits to a sold listing's
    -- description are unaffected.
    if NEW.status is distinct from OLD.status and not public.pm_is_owner() then
      if OLD.status = 'sold' then
        raise exception 'A sold listing cannot change status.';
      end if;
      if OLD.status = 'active' and NEW.status <> 'reserved' then
        raise exception 'An active listing can only be reserved.';
      end if;
      if OLD.status = 'reserved' and NEW.status not in ('active', 'sold') then
        raise exception 'A reserved listing can only go back to active or be marked sold.';
      end if;
    end if;
    if NEW.boost_tier is not null and NEW.boost_tier not in (500, 1000) then
      raise exception 'Unknown boost tier.';
    end if;
    if NEW.boosted_until is not null
      and (NEW.boosted_until < now() or NEW.boosted_until > now() + interval '72 hours')
    then
      raise exception 'A boost can last at most 72 hours from now.';
    end if;
    -- (F6) A boost is a tier AND an expiry, together — and the
    -- expiry must match the tier that was paid for.
    if (NEW.boost_tier is null) <> (NEW.boosted_until is null) then
      raise exception 'A boost needs both a tier and an expiry.';
    end if;
    if NEW.boost_tier = 500 and NEW.boosted_until > now() + interval '25 hours' then
      raise exception 'A 500 naira boost lasts 24 hours.';
    end if;
    if NEW.boost_tier = 1000 and NEW.boosted_until > now() + interval '73 hours' then
      raise exception 'A 1,000 naira boost lasts 72 hours.';
    end if;
    -- (DB-13) While an order is open on this listing, its photos,
    -- title, price and delivery details are frozen — the buyer
    -- bought on what they saw. Status flips and description /
    -- condition edits stay allowed.
    if (NEW.photos is distinct from OLD.photos
        or NEW.title is distinct from OLD.title
        or NEW.price is distinct from OLD.price
        or NEW.delivery_methods is distinct from OLD.delivery_methods
        or NEW.courier is distinct from OLD.courier
        or NEW.meetup_spot is distinct from OLD.meetup_spot
        or NEW.ships_to is distinct from OLD.ships_to)
      and exists (
        select 1 from public.orders o
        where o.listing_id = OLD.id
          and o.status not in ('cancelled')
      ) then
      raise exception 'This listing has an open order — its photos, title, price and delivery details cannot be changed.';
    end if;
    return NEW;
  end if;

  if NEW.id is distinct from OLD.id
    or NEW.seller_id is distinct from OLD.seller_id
    or NEW.seller_label is distinct from OLD.seller_label
    or NEW.title is distinct from OLD.title
    or NEW.description is distinct from OLD.description
    or NEW.price is distinct from OLD.price
    or NEW.condition is distinct from OLD.condition
    or NEW.category is distinct from OLD.category
    or NEW.university is distinct from OLD.university
    or NEW.state is distinct from OLD.state
    or NEW.ships_to is distinct from OLD.ships_to
    or NEW.delivery_methods is distinct from OLD.delivery_methods
    or NEW.courier is distinct from OLD.courier
    or NEW.meetup_spot is distinct from OLD.meetup_spot
    or NEW.photos is distinct from OLD.photos
    or NEW.boost_tier is distinct from OLD.boost_tier
    or NEW.boosted_until is distinct from OLD.boosted_until
    or NEW.views is distinct from OLD.views
    or NEW.created_at is distinct from OLD.created_at
  then
    raise exception 'Only the seller can edit this listing — an order participant may only change its status.';
  end if;
  if NEW.status not in ('active', 'reserved', 'sold') then
    raise exception 'A listing status can only be active, reserved or sold.';
  end if;
  if not exists (
    select 1 from public.orders o
    where o.listing_id = OLD.id
      and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
  ) then
    raise exception 'Only the seller or a party to an order for this listing can change its status.';
  end if;
  -- (M20 SQL-13) Same status allowlist for order participants.
  if NEW.status is distinct from OLD.status then
    if OLD.status = 'sold' then
      raise exception 'A sold listing cannot change status.';
    end if;
    if OLD.status = 'active' and NEW.status <> 'reserved' then
      raise exception 'An active listing can only be reserved.';
    end if;
    if OLD.status = 'reserved' and NEW.status not in ('active', 'sold') then
      raise exception 'A reserved listing can only go back to active or be marked sold.';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_listing_update_trg on public.listings;
create trigger pm_validate_listing_update_trg
  before update on public.listings
  for each row execute function public.pm_validate_listing_update();

-- ---------------------------------------------------------------------------
-- §4) SQL-14 — unfreeze the order when its dispute is resolved. The
-- app already unfreezes on resolve; this is the backstop for a lost
-- write. Safe: one open dispute per order (M16 partial unique index),
-- so resolving it means no open dispute remains. The return gate is
-- separate — an open return still blocks release on its own.
-- ---------------------------------------------------------------------------
create or replace function public.pm_unfreeze_on_dispute_resolve()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status = 'resolved'
    and OLD.status is distinct from 'resolved'
    and NEW.order_id is not null then
    update public.orders
      set frozen = false, updated_at = now()
      where id = NEW.order_id and coalesce(frozen, false);
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_unfreeze_on_dispute_resolve_trg on public.disputes;
create trigger pm_unfreeze_on_dispute_resolve_trg
  after update on public.disputes
  for each row execute function public.pm_unfreeze_on_dispute_resolve();

-- ---------------------------------------------------------------------------
-- §5 + M-3 + M-4 — auto_release_overdue_orders(): milestone-12's live function (NOT milestone-10 — M12 adds the frozen guard, kept here), with the draft §5 prefs check, per-leg checks, per-order exception blocks, and zero-amount legs written like release_order(). M-3 grants follow the function.
-- ---------------------------------------------------------------------------
create or replace function public.auto_release_overdue_orders()
returns setof text
language plpgsql
security definer
set search_path = public
as $$
declare
  o record;
  v_advance integer;
  v_held_out integer;
  v_release_in integer;
  v_has_held_leg boolean := false;
  v_has_avail_leg boolean := false;
  v_held_amount integer;
  v_avail_amount integer;
begin
  for o in
    select *
    from public.orders ord
    where ord.status = 'delivered'
      and ord.payment_method = 'held'
      and ord.delivered_at is not null
      and ord.delivered_at <= now() - interval '48 hours'
      and ord.return_status is distinct from 'opened'
      -- Milestone 12 frozen guard: an order under dispute never
      -- auto-releases while its money is frozen.
      -- (Milestone 22) The table is aliased 'ord': 'o' is the loop
      -- record, and o.frozen inside this query read the unassigned
      -- record and raised "record o is not assigned yet" on every
      -- call — the server-side 48h release could never run at all.
      and not coalesce(ord.frozen, false)
    order by ord.delivered_at asc
    for update skip locked
  loop
    -- (M20 M-4) Each order runs in its own exception block, so one
    -- bad order (wrong leg amounts, a trigger refusal) is skipped
    -- with a NOTICE instead of aborting the whole batch.
    begin
    -- Shipping advance already released for this order (Milestone 8:
    -- half the shipping fee can already sit in "available"). It has
    -- already left "held", so it must not leave "held" a second time
    -- and must not be paid to the seller a second time.
    select coalesce(sum(amount), 0) into v_advance
    from public.wallet_ledger
    where order_id = o.id
      and kind = 'shipping_advance'
      and bucket = 'available';

    v_held_out := greatest(o.total - v_advance, 0);
    v_release_in := greatest(o.item_price + o.shipping_fee - v_advance, 0);

    -- (M20 M-4) Each release leg is checked separately, exactly
    -- like release_order(): a leg already written is verified
    -- against the expected amount (a wrong amount is refused
    -- loudly — the per-order exception block below turns it into
    -- a skipped order, not an aborted batch), and whichever leg is
    -- missing is written. The old code only looked for the held
    -- leg, so a crash between the two writes stranded the
    -- seller's available leg while still flipping the order to
    -- 'released'. Zero-amount legs ARE written (release_order
    -- does the same): the order-update trigger refuses a release
    -- without both legs, so skipping them would strand a 0-naira
    -- order for ever.
    select exists (
      select 1 from public.wallet_ledger
      where order_id = o.id and kind = 'release' and bucket = 'held'
    ) into v_has_held_leg;

    select exists (
      select 1 from public.wallet_ledger
      where order_id = o.id and kind = 'release' and bucket = 'available'
    ) into v_has_avail_leg;

    if v_has_held_leg then
      select amount into v_held_amount
      from public.wallet_ledger
      where order_id = o.id and kind = 'release' and bucket = 'held';
      if v_held_amount <> -v_held_out then
        raise exception 'The release legs for this order do not match — ask the PulseMarket team to check it.';
      end if;
    end if;
    if v_has_avail_leg then
      select amount into v_avail_amount
      from public.wallet_ledger
      where order_id = o.id and kind = 'release' and bucket = 'available';
      if v_avail_amount <> v_release_in then
        raise exception 'The release legs for this order do not match — ask the PulseMarket team to check it.';
      end if;
    end if;

    if not v_has_held_leg then
      insert into public.wallet_ledger
        (order_id, user_id, bucket, kind, amount, note, created_by)
      values
        (o.id, o.seller_id, 'held', 'release', -v_held_out,
         'Auto-release (48h) — released from hold for order ' || o.code,
         o.buyer_id);
    end if;
    if not v_has_avail_leg then
      insert into public.wallet_ledger
        (order_id, user_id, bucket, kind, amount, note, created_by)
      values
        (o.id, o.seller_id, 'available', 'release', v_release_in,
         'Auto-release (48h) — released to seller for order ' || o.code,
         o.buyer_id);
    end if;

    update public.orders
    set status = 'released',
        released_at = coalesce(released_at, now()),
        updated_at = now()
    where id = o.id;

    update public.listings
    set status = 'sold'
    where id = o.listing_id;

    -- Tell both parties, unless that party turned release
    -- notifications off (M20 SQL-12 / draft §5). This insert is
    -- inside the SECURITY DEFINER function, so it is NOT blocked
    -- by the notifications RLS the way app-side cross-user
    -- inserts are, and it does NOT go through
    -- insert_notification() — pg_cron has no auth.uid(), so the
    -- prefs table is read directly here instead. No prefs row (or
    -- no prefs table at all) means everything on. It must never
    -- block the release itself, so a failure here is swallowed.
    begin
      if to_regclass('public.notification_prefs') is null
        or not exists (
          select 1 from public.notification_prefs
          where user_id = o.buyer_id
            and coalesce(release_enabled, true) = false
        ) then
        insert into public.notifications (user_id, kind, title, body, link)
        values
          (o.buyer_id, 'release',
           'Money released for order ' || o.code,
           '48 hours passed since delivery, so the held money for order ' || o.code || ' was released to the seller.',
           '/order/' || o.id::text);
      end if;
      if to_regclass('public.notification_prefs') is null
        or not exists (
          select 1 from public.notification_prefs
          where user_id = o.seller_id
            and coalesce(release_enabled, true) = false
        ) then
        insert into public.notifications (user_id, kind, title, body, link)
        values
          (o.seller_id, 'release',
           'Money released for order ' || o.code,
           '48 hours passed since delivery, so the held money for order ' || o.code || ' was released to your available balance.',
           '/order/' || o.id::text);
      end if;
    exception when others then
      null;
    end;

    return next o.code;
    exception when others then
      raise notice 'Auto-release skipped order %: %', o.code, sqlerrm;
    end;
  end loop;
  return;
end;
$$;

revoke execute on function public.auto_release_overdue_orders() from public;
grant execute on function public.auto_release_overdue_orders() to authenticated;

-- ---------------------------------------------------------------------------
-- §6) SQL-7 — a report needs an order in a state money can move in.
-- Reproduced from supabase/milestone-16.sql (lines 1453-1502) with
-- ONLY the status gate added. Filing on a 'reserved' order then
-- freezing it used to block the buyer cancelling until the team
-- unfreezes. The app already refuses this (src/lib/disputes.js);
-- the database is the backstop for a direct API call.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_dispute_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.status is distinct from 'open' then
    raise exception 'A new report always starts as open.';
  end if;
  if NEW.category not in (
    'Item not as described',
    'Item never arrived',
    'Item damaged',
    'Wrong item',
    'Seller unresponsive',
    'Payment problem',
    'Other'
  ) then
    raise exception 'Choose what went wrong from the list.';
  end if;
  if NEW.explanation is null
    or char_length(btrim(NEW.explanation)) < 20
    or char_length(btrim(NEW.explanation)) > 2000 then
    raise exception 'Explain what happened in at least 20 characters (under 2,000).';
  end if;
  if NEW.email is null
    or char_length(btrim(NEW.email)) > 120
    or btrim(NEW.email) !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then
    raise exception 'Enter a valid email address so the team can reach you.';
  end if;
  -- (M20) A report can only be filed on an order that has been paid,
  -- held, shipped or delivered. A 'reserved' order has no money in
  -- it — filing there only freezes an order the buyer should be free
  -- to cancel.
  if not exists (
    select 1 from public.orders
    where id = NEW.order_id
      and status in ('paid', 'held', 'shipped', 'delivered')
  ) then
    raise exception 'A report can only be filed on an order that has been paid, held, shipped or delivered.';
  end if;
  if not exists (
    select 1 from public.evidence
    where order_id = NEW.order_id
      and kind = 'dispute'
      and verified = true
  ) then
    raise exception 'Add evidence first — record a short video of the problem in the app (dispute evidence, 10–20 seconds) before reporting it.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_dispute_insert_trg on public.disputes;
create trigger pm_validate_dispute_insert_trg
  before insert on public.disputes
  for each row execute function public.pm_validate_dispute_insert();

-- ---------------------------------------------------------------------------
-- §7) SQL-10 — NULL offer_status bypass. Reproduced from
-- supabase/m19/01-chat-gates.sql §5 with ONLY the two coalesce()
-- fixes: a plain text message (offer_status NULL) could be flipped
-- to 'accepted', and pending -> NULL slipped past the check entirely
-- (NULL is not true in an IF). No money impact on its own — the
-- agreed price still needs an accepted offer with an amount — but an
-- offer must not be killable or fakable this way.
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
    if coalesce(OLD.offer_status, '') <> 'pending'
      or coalesce(NEW.offer_status, '') not in ('accepted', 'declined') then
      raise exception 'Only a pending offer can be accepted or declined.';
    end if;
    -- (Milestone 22) The sender may DECLINE their own offer — that
    -- is withdrawing it, and it can only remove a pending offer,
    -- never set an agreed price. Accepting your own offer is still
    -- refused. The distinction matters because respond_offer()
    -- declines the acceptor's own pending offers when a deal is
    -- struck (acceptance is terminal); the old blanket refusal made
    -- that whole accept roll back.
    if auth.uid() = OLD.sender_id and NEW.offer_status = 'accepted' then
      raise exception 'You cannot accept your own offer.';
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
-- §8) SQL-11 — a pickup ticket cannot be moved to another conversation
-- or order. Reproduced from supabase/m19/01-chat-gates.sql §4 with
-- ONLY the immutability check added at the top: the old early return
-- (spot/date/time unchanged) let a conversation_id / order_id change
-- slip through unexamined.
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
  -- (M20) A ticket belongs to its conversation and order — it can
  -- never be re-pointed at a different chat.
  if NEW.conversation_id is distinct from OLD.conversation_id
    or NEW.order_id is distinct from OLD.order_id then
    raise exception 'A pickup ticket cannot be moved to another conversation or order.';
  end if;
  if NEW.meetup_spot is not distinct from OLD.meetup_spot
    and NEW.date is not distinct from OLD.date
    and NEW.time is not distinct from OLD.time then
    return NEW;
  end if;
  -- (Milestone 22) The old check never fired for a stranger: when
  -- the caller is neither buyer nor seller, the CASE falls through
  -- to the buyer, so v_other was non-null and no error was raised.
  -- Check membership directly (RLS backstops it live, but the
  -- trigger must not depend on that). v_other is still computed
  -- below for the blocked check.
  if not exists (
    select 1 from public.conversations
    where id = NEW.conversation_id
      and (buyer_id = auth.uid() or seller_id = auth.uid())
  ) then
    raise exception 'You are not part of this conversation.';
  end if;
  select case when buyer_id = auth.uid() then seller_id else buyer_id end
    into v_other
    from public.conversations
    where id = NEW.conversation_id;
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
-- §9) SQL-9 — review_verification guards. Reproduced from
-- supabase/m19/02-verification.sql §3 with ONLY these changes:
--   * approving a FLAGGED account is refused (unflag first);
--   * approving requires the row to be 'pending review' — a rejected
--     row must come back through resubmit, not a quiet re-approve;
--   * rejecting is allowed from 'pending review' or 'approved' (the
--     later-rejection path) but not from 'rejected' again.
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
  v_current text;
  v_flagged boolean;
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
  -- (M20) Read the row's current state first: the guards below need
  -- it, and a missing row is refused here instead of at the update.
  select status, coalesce(flagged, false) into v_current, v_flagged
    from public.verifications
    where user_id = p_user_id;
  if not found then
    raise exception 'That student has no verification to review.';
  end if;
  -- (M20) A flagged account cannot be approved — unflag it first.
  -- Flagged checks still block posting/ordering, so approving one
  -- would be contradictory.
  if p_status = 'approved' and v_flagged then
    raise exception 'That account is flagged — unflag it before approving.';
  end if;
  -- (M20) An approval only ever moves 'pending review' forward. A
  -- rejected student comes back through resubmit, not a quiet
  -- re-approve; a rejection from 'approved' is the later-rejection
  -- path and stays allowed.
  if p_status = 'approved' and v_current <> 'pending review' then
    raise exception 'Only a verification under review can be approved.';
  end if;
  if p_status = 'rejected' and v_current not in ('pending review', 'approved') then
    raise exception 'That verification is already rejected.';
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
end;
$$;

revoke execute on function public.review_verification(uuid, text, text, text) from public;
grant execute on function public.review_verification(uuid, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- §10) SQL-8 — a photo-less 'pending review' row can resubmit.
-- Reproduced from supabase/m19/02-verification.sql §5 with ONLY the
-- status check changed: a pending row that is MISSING a photo (made
-- between the M17 and M18 runs, when inserts did not require photos)
-- has no other way to add one — approval refuses photo-less rows,
-- and replace_verification_photos is for swapping photos, not for a
-- row that never had them. A pending row WITH both photos still
-- cannot resubmit (use Replace photos in the app). The update
-- trigger already allows pending -> pending in the resubmit branch.
-- ---------------------------------------------------------------------------
create or replace function public.resubmit_verification(p_front_url text, p_back_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_front text;
  v_back text;
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
  select status, id_front_url, id_back_url into v_status, v_front, v_back
    from public.verifications
    where user_id = auth.uid();
  if not found then
    raise exception 'You have no verification to resubmit — submit it first.';
  end if;
  -- (M20) Rejected rows resubmit as before. A pending row resubmits
  -- ONLY when it is missing a photo — the rows M17 let through
  -- without photos. A pending row with both photos uses Replace
  -- photos instead (and, until APP-1 is fixed, the team rejects it
  -- so the student can resubmit normally).
  if v_status = 'pending review' then
    if nullif(btrim(coalesce(v_front, '')), '') is not null
      and nullif(btrim(coalesce(v_back, '')), '') is not null then
      raise exception 'Your photos are already in — use Replace photos while you wait, or wait for the team review.';
    end if;
  elsif v_status <> 'rejected' then
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
-- §11) SQL-2 + SQL-3 — release_order(): party check first, listing to
-- 'sold' in-transaction, and existing legs verified by amount.
-- Reproduced from supabase/m19/04-notifications-release.sql §5 with
-- ONLY these changes (marked M20):
--   * (a) a party check (buyer / seller / team) runs right after the
--     row lock, BEFORE the already-released early return and the
--     status errors — the old code handed the full order row (or a
--     status-revealing error) to any authenticated caller who knew
--     the order UUID;
--   * (b) the advance + expected amounts are computed before the
--     early return, and any release leg already written is checked
--     against the expected amount — a half-move leg with a wrong
--     amount is refused loudly instead of papered over;
--   * (c) the listing flips to 'sold' in the SAME transaction (the
--     old code left it to the app's best-effort follow-up, so a crash
--     left a released order's listing buyable again).
--   NOT changed: zero-amount legs are still written (a ₦0 order
--   needs both legs to exist for the status trigger to accept the
--   move — skipping them would break the release, not fix it).
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
  v_held_amount integer;
  v_avail_amount integer;
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

  -- (M20-a) Party check FIRST: nobody who is not the buyer, the
  -- seller or the team learns anything about this order — not even
  -- whether it is already released. (The full actor check with the
  -- seller's 48h rule still runs below, before any money moves.)
  if not (v_caller = v_order.buyer_id
          or v_caller = v_order.seller_id
          or public.pm_is_owner()) then
    raise exception 'Only the buyer, the seller or the PulseMarket team can release this order.';
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

  -- Money math, re-derived from the order: the shipping advance
  -- already paid is subtracted from both legs so the seller is
  -- never paid the same money twice. An advance can never exceed
  -- the shipping fee (the ledger trigger's held-sum backstop
  -- refuses it), so total - advance stays positive for any real
  -- order; a negative value here means corrupt data, so refuse
  -- instead of writing a nonsense leg.
  -- (M20-b) Computed here, before the early return, so the leg
  -- amounts below can be verified against it.
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

  -- Already released, money already moved: return the order
  -- as-is, never pay twice. (A 'released' order with NO release
  -- legs cannot exist — the order-update trigger refuses it — so
  -- one that is ever found is refused loudly instead of papered
  -- over.)
  if v_order.status = 'released' then
    if v_has_held_leg and v_has_avail_leg then
      -- (M20-b) A half-move leg with a WRONG amount must never be
      -- papered over by returning the order as-is.
      select amount into v_held_amount
      from public.wallet_ledger
      where order_id = v_order.id and kind = 'release' and bucket = 'held';
      if v_held_amount <> -v_held_out then
        raise exception 'The release legs for this order do not match — ask the PulseMarket team to check it.';
      end if;
      select amount into v_avail_amount
      from public.wallet_ledger
      where order_id = v_order.id and kind = 'release' and bucket = 'available';
      if v_avail_amount <> v_avail_in then
        raise exception 'The release legs for this order do not match — ask the PulseMarket team to check it.';
      end if;
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

  -- (M20-b) Any release leg already written must equal the expected
  -- amount — a retried call or a pre-M19 half-move with a wrong
  -- amount is refused loudly instead of completed blindly.
  if v_has_held_leg then
    select amount into v_held_amount
    from public.wallet_ledger
    where order_id = v_order.id and kind = 'release' and bucket = 'held';
    if v_held_amount <> -v_held_out then
      raise exception 'The release legs for this order do not match — ask the PulseMarket team to check it.';
    end if;
  end if;
  if v_has_avail_leg then
    select amount into v_avail_amount
    from public.wallet_ledger
    where order_id = v_order.id and kind = 'release' and bucket = 'available';
    if v_avail_amount <> v_avail_in then
      raise exception 'The release legs for this order do not match — ask the PulseMarket team to check it.';
    end if;
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

  -- (M20-c) The listing flips to sold in the same transaction.
  -- The old code left it to the app's best-effort follow-up, so an
  -- app crash after the RPC left a released order's listing
  -- buyable again. (The app may still set it — setting 'sold'
  -- twice is harmless.)
  update public.listings
  set status = 'sold'
  where id = v_order.listing_id;

  return v_order;
end;
$$;

revoke execute on function public.release_order(uuid) from public;
grant execute on function public.release_order(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- §12-(A) + D-3 + M-1 — pm_validate_ledger_insert(): milestone-17's live function with ONLY the team-refund carve-out extended to held/shipped/delivered, the seller-fault refund amount changed to the FULL total (D-3), and the team-refund buyer leg set to item + shipping (fees stay with PulseMarket, owner decision 2026-11-26). Read the M-1 note inside the refund branch before touching the amounts.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_ledger_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_advance integer := 0;
  v_half integer := 0;
  v_held_sum integer := 0;
  v_owed integer := 0;
  v_avail_sum integer := 0;
begin
  if auth.uid() is null then
    return NEW;
  end if;

  if NEW.kind in ('hold', 'release', 'shipping_advance', 'refund')
    and NEW.order_id is null then
    raise exception 'A % ledger entry needs an order.', NEW.kind;
  end if;

  if NEW.order_id is not null then
    -- (F4) Lock the order row first: every sum read below (advance,
    -- held sum, owed debt) is then taken after the lock, so two
    -- concurrent money moves for this order queue here and the
    -- second one sees the first one's committed rows. The app's
    -- paired insert holds the lock for both of its rows (same
    -- transaction), and auto_release_overdue_orders() already holds
    -- it (FOR UPDATE SKIP LOCKED) — re-locking in the same
    -- transaction is a no-op.
    select * into v_order from public.orders where id = NEW.order_id for update;
    if not found then
      raise exception 'That order does not exist.';
    end if;
    -- Shipping advance already paid out for this order.
    select coalesce(sum(amount), 0) into v_advance
    from public.wallet_ledger
    where order_id = NEW.order_id
      and kind = 'shipping_advance'
      and bucket = 'available';
  end if;

  -- Frozen money does not move: the team resolves the dispute first.
  if NEW.kind in ('hold', 'release', 'shipping_advance', 'refund', 'debt')
    and NEW.order_id is not null
    and coalesce(v_order.frozen, false) then
    raise exception 'This order is frozen — a dispute is open. The PulseMarket team resolves it first.';
  end if;

  if NEW.kind = 'hold' then
    if not public.pm_is_owner() then
      raise exception 'Only the PulseMarket team can hold money for an order.';
    end if;
    if v_order.payment_method <> 'held' then
      raise exception 'Cash orders never hold money.';
    end if;
    -- (F11) A hold is the team confirming the buyer's transfer
    -- arrived, which only ever happens while the order is 'paid'.
    if v_order.status <> 'paid' then
      raise exception 'A hold can only be recorded once the buyer has marked the order paid.';
    end if;
    if NEW.user_id <> v_order.seller_id or NEW.bucket <> 'held'
      or NEW.amount <> v_order.total then
      raise exception 'A hold must put the order total in the seller''s held bucket.';
    end if;
  elsif NEW.kind = 'release' then
    -- (DB-1a) Only the buyer, the team, or the seller after 48h can
    -- release held money. Without this, the seller could insert
    -- the two release rows themselves while the order is still
    -- 'held' and take the money before delivery — the trigger only
    -- checked amounts and status, never who was writing. The seller
    -- branch mirrors the order-update trigger (48h auto-release
    -- only). The buyer-fault remaining-shipping leg is written by
    -- the team, so pm_is_owner() covers it.
    if not (auth.uid() = v_order.buyer_id or public.pm_is_owner()
      or (auth.uid() = v_order.seller_id and v_order.status = 'delivered'
          and v_order.delivered_at is not null
          and v_order.delivered_at <= now() - interval '48 hours')) then
      raise exception 'Only the buyer, the PulseMarket team, or the seller after 48 hours can release held money.';
    end if;
    if v_order.payment_method <> 'held' then
      raise exception 'Cash orders never release held money.';
    end if;
    if NEW.user_id <> v_order.seller_id then
      raise exception 'A release pays the seller of the order.';
    end if;
    if not exists (
      select 1 from public.wallet_ledger
      where order_id = NEW.order_id and kind = 'hold' and bucket = 'held'
    ) then
      raise exception 'A release needs the money to be held first.';
    end if;
    if NEW.bucket = 'held' then
      if v_order.status <> 'delivered' then
        raise exception 'A release can only be written once delivery is confirmed.';
      end if;
      if coalesce(v_order.return_status, '') = 'opened' then
        raise exception 'A return is open — the held money cannot be released.';
      end if;
      if NEW.amount <> -(v_order.total - v_advance) then
        raise exception 'A release must take exactly what is still held (total minus any advance already paid).';
      end if;
    elsif NEW.bucket = 'available' then
      -- The full release, or the remaining-shipping leg of a
      -- buyer-fault return (the buyer gets the item price back, the
      -- seller keeps the rest of the shipping fee).
      if NEW.amount = greatest(v_order.item_price + v_order.shipping_fee - v_advance, 0)
        and coalesce(v_order.return_status, '') <> 'opened' then
        if v_order.status <> 'delivered' then
          raise exception 'A release can only be written once delivery is confirmed.';
        end if;
        if not exists (
          select 1 from public.wallet_ledger
          where order_id = NEW.order_id and kind = 'release' and bucket = 'held'
        ) then
          raise exception 'A release to the seller needs its held leg first.';
        end if;
      elsif coalesce(v_order.return_status, '') = 'opened'
        and NEW.amount = greatest(v_order.shipping_fee - v_advance, 0) then
        -- Buyer-fault return leg: written while the order is still
        -- shipped or delivered, as part of resolving the return.
        if v_order.status not in ('shipped', 'delivered') then
          raise exception 'The remaining-shipping leg can only be written while the order is shipped or delivered.';
        end if;
        if not exists (
          select 1 from public.wallet_ledger
          where order_id = NEW.order_id and kind = 'refund' and bucket = 'held'
        ) then
          raise exception 'The remaining-shipping leg needs the refund held leg first.';
        end if;
      else
        raise exception 'A release must pay the seller exactly the item price plus the shipping fee, minus any advance already paid.';
      end if;
    else
      raise exception 'A release moves money between held and available only.';
    end if;
  elsif NEW.kind = 'shipping_advance' then
    -- (DB-1d) Only the seller (or the team fixing a record) can
    -- claim the shipping advance. The trigger already checks the
    -- row pays the seller; this checks who is writing it.
    if auth.uid() <> v_order.seller_id and not public.pm_is_owner() then
      raise exception 'Only the seller can claim the shipping advance.';
    end if;
    if v_order.payment_method <> 'held' or v_order.status not in ('shipped', 'delivered') then
      raise exception 'A shipping advance is only paid once the order has shipped.';
    end if;
    -- (F10) `NULL NOT IN (...)` is NULL, never true, so a missing
    -- courier used to skip this check entirely. It is spelled out
    -- now (the only way to reach here with no courier is a
    -- meet-in-person order, whose shipping fee is 0, so the only
    -- thing the old gap could ever write was a pair of 0 rows).
    if v_order.courier is null
      or v_order.courier not in ('GIG Logistics', 'GUO Transport', 'DHL Domestic', 'Peace Logistics', 'ABC Transport') then
      raise exception 'This courier never earns a shipping advance.';
    end if;
    -- The proof must already be on the order: the app saves the
    -- waybill number + receipt photo and ships the order first, so
    -- an advance with no proof behind it is refused here.
    if v_order.waybill_number is null or btrim(v_order.waybill_number) = ''
      or v_order.receipt_photo is null then
      raise exception 'A shipping advance needs the waybill number and receipt photo on the order.';
    end if;
    if NEW.user_id <> v_order.seller_id then
      raise exception 'A shipping advance pays the seller of the order.';
    end if;
    v_half := v_order.shipping_fee / 2;
    if NEW.bucket = 'held' and NEW.amount <> -v_half then
      raise exception 'A shipping advance moves exactly half the shipping fee out of hold.';
    elsif NEW.bucket = 'available' then
      if NEW.amount <> v_half then
        raise exception 'A shipping advance pays exactly half the shipping fee.';
      end if;
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = NEW.order_id and kind = 'shipping_advance' and bucket = 'held'
      ) then
        raise exception 'A shipping advance to the seller needs its held leg first.';
      end if;
    elsif NEW.bucket not in ('held', 'available') then
      raise exception 'A shipping advance moves money between held and available only.';
    end if;
  elsif NEW.kind = 'refund' then
    -- (M20 D-3 / M-1 — READ THIS BEFORE CHANGING THE AMOUNTS
    -- BELOW.) A buyer who is refunded loses NOTHING when the
    -- seller is at fault (seller-fault return: FULL total), and
    -- the books must still balance. A TEAM refund with no return
    -- open is different: the buyer gets item + shipping back and
    -- the fees stay with PulseMarket (owner decision 2026-11-26).
    -- The old amounts created money whenever a shipping advance
    -- had been paid: the buyer leg paid item + shipping in full
    -- (8,500) while the seller KEPT the advance (1,750) with no
    -- debt recorded — 8,500 + 1,750 = 10,250 out of 8,925 held,
    -- so 1,325 naira was conjured out of nothing on a 5,000 /
    -- 3,500 order with a 1,750 advance. The fixed leg design is:
    --   * refund held leg, seller: -(total - advance)
    --   * refund available leg, buyer: +total for a seller-fault
    --     return (the FULL total, fees included); +(item_price +
    --     shipping_fee) for a team refund with no return open
    --     (NOT the total, NOT total - advance)
    --   * seller debt leg, seller available: -advance (kind
    --     'debt', written by the team via recordSellerDebt; skip
    --     it when advance = 0)
    -- The buyer nets the refund amount; the seller nets 0
    -- (advance received, then owed straight back); the hold
    -- drains to 0; on a team refund the fee stays with
    -- PulseMarket.
    -- WHY THERE IS NO SEPARATE +advance BUYER LEG: the
    -- wallet_ledger_one_refund_idx unique index allows exactly
    -- ONE 'refund' row per (order, bucket), so a second
    -- buyer-available refund row and a seller-available refund
    -- row can never exist — the +advance is folded into the
    -- buyer's leg instead (+total on a seller-fault return,
    -- +item + shipping on a team refund), and the clawback rides
    -- on the existing 'debt' kind (one debt per order, draft §2
    -- index), which is exactly what resolveReturn already
    -- records. The net money movement is identical to the
    -- four-leg sketch (held -(total-advance); buyer +(refund
    -- amount - advance); seller -advance; buyer +advance) —
    -- only the row shape differs.
    -- Buyer-fault is unchanged and already balances: refund
    -- available pays the buyer the item price only, and the
    -- 'release' remaining-shipping leg pays the seller
    -- (shipping - advance), so the buyer nets
    -- item + shipping - advance and the seller keeps the advance.
    -- (DB-2) Cash orders never hold money, so they can never refund
    -- through the ledger. A cash return is sorted out face to face.
    if v_order.payment_method <> 'held' then
      raise exception 'Cash orders never refund through the ledger.';
    end if;
    -- (DB-1b) A refund while a return is open is the team's job:
    -- the buyer opens the return, the team adjudicates fault. A
    -- buyer inserting refund rows directly could pick 'Seller
    -- fault' and pay themselves in full with no adjudication. (A
    -- cancel reversal from reserved/paid has no return open, so it
    -- is unaffected.)
    if coalesce(v_order.return_status, '') = 'opened' and not public.pm_is_owner() then
      raise exception 'Only the PulseMarket team can write a refund while a return is open.';
    end if;
    if NEW.bucket = 'held' then
      if NEW.user_id <> v_order.seller_id
        or NEW.amount <> -(v_order.total - v_advance) then
        raise exception 'A refund must take exactly what is still held (total minus any advance already paid).';
      end if;
      -- Either a return is open (the normal refund), or the order
      -- is still reserved/paid and the hold is being reversed on
      -- cancellation — or (F2) the team is refunding a held order
      -- the seller never shipped, with no return open.
      if coalesce(v_order.return_status, '') <> 'opened'
        and v_order.status not in ('reserved', 'paid')
        and not (public.pm_is_owner() and v_order.status in ('held', 'shipped', 'delivered')) then
        raise exception 'A refund out of hold needs an open return, or a team refund of a held, shipped or delivered order.';
      end if;
    elsif NEW.bucket = 'available' then
      if public.pm_is_owner() and v_order.status in ('held', 'shipped', 'delivered')
        and coalesce(v_order.return_status, '') <> 'opened' then
        -- (F2) Team refund with no return open (refundHeldOrder):
        -- owner decision 2026-11-26 — team refunds KEEP the fee:
        -- the buyer gets item + shipping back, NOT the total. A
        -- held order never shipped has no advance; on a
        -- shipped/delivered order the app must also record the
        -- shipping advance as a seller debt (recordSellerDebt,
        -- -advance) so the seller does not keep money the buyer
        -- was refunded — see the M-1 note at the top of the
        -- refund branch. No return is open, so the fault-amount
        -- rules below do not apply.
        if NEW.user_id <> v_order.buyer_id
          or NEW.amount <> v_order.item_price + v_order.shipping_fee then
          raise exception 'A team refund pays the buyer the item price plus the shipping fee — the fees stay with PulseMarket.';
        end if;
      else
        if coalesce(v_order.return_status, '') <> 'opened' then
          raise exception 'A refund to the buyer needs an open return.';
        end if;
        if v_order.status not in ('shipped', 'delivered') then
          raise exception 'A refund to the buyer can only be written once the order has shipped.';
        end if;
        if NEW.user_id <> v_order.buyer_id then
          raise exception 'A refund pays the buyer of the order.';
        end if;
        if v_order.return_reason like 'Seller fault%' then
          -- (M20 D-3 / M-1) The buyer gets the FULL total back,
          -- fees included. The amount is the total — NOT
          -- item + shipping and NOT total - advance (the advance
          -- is clawed back separately as a seller debt; see the
          -- note at the top of the refund branch).
          if NEW.amount <> v_order.total then
            raise exception 'A seller-fault refund pays the buyer the order total in full.';
          end if;
        elsif v_order.return_reason like 'Buyer fault%' then
          if NEW.amount <> v_order.item_price then
            raise exception 'A buyer-fault refund pays the buyer the item price only.';
          end if;
        else
          raise exception 'A refund to the buyer needs a return reason that says whose fault it is.';
        end if;
      end if;
      if not exists (
        select 1 from public.wallet_ledger
        where order_id = NEW.order_id and kind = 'refund' and bucket = 'held'
      ) then
        raise exception 'A refund to the buyer needs its held leg first.';
      end if;
    else
      raise exception 'A refund moves money between held and available only.';
    end if;
  elsif NEW.kind = 'debt' then
    if not public.pm_is_owner() then
      raise exception 'Only the PulseMarket team can record a seller debt.';
    end if;
    if NEW.order_id is not null and NEW.user_id <> v_order.seller_id then
      raise exception 'A seller debt belongs to the seller of the order.';
    end if;
    if NEW.bucket <> 'available' or NEW.amount >= 0 then
      raise exception 'A seller debt is a negative available entry.';
    end if;
  elsif NEW.kind = 'repayment' then
    -- (DB-1c) A repayment is the team recording money the seller
    -- paid back. A seller writing repayment rows for themselves
    -- would clear their own debt with no payment — and no app code
    -- ever writes a repayment, so a direct API insert is currently
    -- the only way one appears.
    if not public.pm_is_owner() then
      raise exception 'Only the PulseMarket team can record a repayment.';
    end if;
    if NEW.order_id is null then
      raise exception 'A repayment needs an order.';
    end if;
    if NEW.user_id <> v_order.seller_id then
      raise exception 'A repayment belongs to the seller who owed the debt.';
    end if;
    -- (Milestone 22) A repayment settles the debt WITHOUT crediting
    -- the seller's withdrawable balance, so it lives in the
    -- 'settled' bucket, never 'available'. The old rule wrote it as
    -- a positive 'available' entry: after a seller-fault refund the
    -- seller's available balance is advance (+1,750) + debt (-1,750)
    -- = 0, and recording the genuine 1,750 repayment as +1,750
    -- 'available' put the balance back to +1,750 — money the seller
    -- had already received once as the advance and then paid back.
    -- Withdrawing it would have paid the advance twice. The debt
    -- math is unchanged: sellerDebtAmount() nets 'debt' against
    -- 'repayment' by kind (no bucket filter), and the balances RPC
    -- and the app only sum the 'held' and 'available' buckets, so a
    -- 'settled' repayment is invisible to withdrawable balances.
    -- The cap below is kind-based, so it still caps the repayment
    -- at the outstanding debt. (The wallet_ledger bucket CHECK is
    -- widened to include 'settled' in §8 of milestone-22.sql.)
    if NEW.bucket <> 'settled' or NEW.amount <= 0 then
      raise exception 'A repayment settles a debt without crediting the seller — it lives in the settled bucket.';
    end if;
    -- A repayment may never exceed what the seller still owes on
    -- this order — otherwise a seller could mint money by writing
    -- repayment rows for themselves. (The order-row lock above
    -- serialises concurrent repayments, so two at once cannot both
    -- pass against the same outstanding debt.)
    select coalesce(sum(abs(amount)), 0) into v_owed
    from public.wallet_ledger
    where order_id = NEW.order_id and kind = 'debt';
    select v_owed - coalesce(sum(amount), 0) into v_owed
    from public.wallet_ledger
    where order_id = NEW.order_id and kind = 'repayment';
    if NEW.amount > v_owed then
      raise exception 'A repayment cannot exceed the debt still owed on this order.';
    end if;
  elsif NEW.kind = 'withdrawal' then
    if NEW.bucket <> 'available' or NEW.amount >= 0
      or NEW.user_id <> auth.uid() then
      raise exception 'A withdrawal takes money out of your own available balance.';
    end if;
    -- (F4) A withdrawal usually has no order to lock, so serialise
    -- per user instead: two concurrent withdrawals can no longer
    -- both read the same balance and both pass.
    perform pg_advisory_xact_lock(727001, hashtext(NEW.user_id::text));
    select coalesce(sum(amount), 0) into v_avail_sum
    from public.wallet_ledger
    where user_id = NEW.user_id and bucket = 'available';
    if v_avail_sum + NEW.amount < 0 then
      raise exception 'A withdrawal cannot take more than the available balance.';
    end if;
  end if;

  -- Held money can never leave hold more than entered: the order's
  -- held sum must stay >= 0 after this row. This is the backstop
  -- against a release and a refund (or any two racing money moves)
  -- draining the same hold twice — the unique indexes only stop
  -- two rows of the SAME kind. (F4) The order-row lock taken above
  -- is what makes this read-then-check safe against a concurrent
  -- move: the second move waits, then re-reads the sum including
  -- the first move's committed rows.
  if NEW.bucket = 'held' and NEW.amount < 0 and NEW.order_id is not null then
    select coalesce(sum(amount), 0) into v_held_sum
    from public.wallet_ledger
    where order_id = NEW.order_id and bucket = 'held';
    if v_held_sum + NEW.amount < 0 then
      raise exception 'There is not enough money held for this order to cover this move.';
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_ledger_insert_trg on public.wallet_ledger;
create trigger pm_validate_ledger_insert_trg
  before insert on public.wallet_ledger
  for each row execute function public.pm_validate_ledger_insert();

-- ---------------------------------------------------------------------------
-- §12-(B) + §12-(C) + M-7 — pm_validate_order_update(): m19/03 live function with ONLY the return-reason correction (widened — see header note B-2), the rider team branch, and the M-7 fault-prefix requirement at return opening. D-4 verified: buyer and seller may both cancel a 'reserved' order (section 4), so the app-side reservation sweep is not blocked.
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
      -- (M20 M-7) The reason must travel with the opening: a
      -- return opened without a fault-prefixed reason can never
      -- be refunded, because the ledger prices the refund from
      -- the stored reason prefix. The app always sets it; this
      -- is the backstop for a direct API call.
      if NEW.return_reason is null
        or (NEW.return_reason not like 'Seller fault%'
            and NEW.return_reason not like 'Buyer fault%') then
        raise exception 'Opening a return needs a reason that starts with "Seller fault" or "Buyer fault".';
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
    -- (M20 §12-B, WIDENED — see the file header, note B-2.) The
    -- team may correct the fault label while the return is open
    -- (staying 'opened') or in the same update that resolves it.
    -- The correction MUST land before the refund legs are written:
    -- the ledger prices the refund from the stored reason at
    -- insert time, and once the return is resolved the ledger
    -- refuses refund legs outright — so a correction allowed ONLY
    -- at resolution would always arrive too late to price the
    -- refund. resolveReturn must therefore write the corrected
    -- reason FIRST (its own order update), then the refund legs,
    -- then the resolving update.
    if v_owner and OLD.return_status = 'opened'
      and NEW.return_status in ('opened', 'resolved') then
      null;
    elsif not (v_is_buyer and NEW.return_status = 'opened'
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
    -- (M20 §12-C) The team may set rider details any time
    -- EXCEPT on a terminal order, and never smuggled with a status
    -- change.
    if v_owner and NEW.status = OLD.status
      and OLD.status not in ('cancelled', 'refunded', 'released') then
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

-- ---------------------------------------------------------------------------
-- D-1 + M-13 — pm_validate_message_insert(): m19/01 live function with ONLY the D-1 open-order exemption for plain text messages and the M-13 kind whitelist + server-side rate limit. Pickup inserts/updates, offer answers and agreed prices stay gated (see below — pickup update is draft §8, message update is draft §7, conversation update is in the M-10 section).
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
  v_listing_id uuid;
begin
  if auth.uid() is null then
    return NEW;
  end if;
  -- (Milestone 22) The old check never fired for a stranger: when
  -- the caller is neither buyer nor seller, the CASE falls through
  -- to the buyer, so v_other was non-null and no error was raised.
  -- Check membership directly (RLS backstops it live, but the
  -- trigger must not depend on that). v_other is still computed
  -- below for the blocked check.
  if not exists (
    select 1 from public.conversations
    where id = NEW.conversation_id
      and (buyer_id = auth.uid() or seller_id = auth.uid())
  ) then
    raise exception 'You are not part of this conversation.';
  end if;
  select case when buyer_id = auth.uid() then seller_id else buyer_id end
    into v_other
    from public.conversations
    where id = NEW.conversation_id;
  if exists (
    select 1 from public.blocked_users
    where (blocker_id = auth.uid() and blocked_id = v_other)
       or (blocker_id = v_other and blocked_id = auth.uid())
  ) then
    raise exception 'You cannot message this student.';
  end if;
  -- (M20 M-13) Server-side send limits: at most 1 message per 2
  -- seconds and 30 per minute, per conversation per sender. The
  -- app throttles per device (src/lib/chat.js); a direct API
  -- caller could otherwise flood a chat. Only plain messages and
  -- offers can be inserted — kind 'system' is never a user
  -- message (the messages table CHECK still lists it, but no app
  -- or team path inserts one).
  if NEW.kind not in ('text', 'offer') then
    raise exception 'A message must be a plain message or an offer.';
  end if;
  if exists (
    select 1 from public.messages
    where conversation_id = NEW.conversation_id
      and sender_id = auth.uid()
      and created_at > now() - interval '2 seconds'
  ) then
    raise exception 'You are sending messages too fast — wait a moment and try again.';
  end if;
  if (select count(*) from public.messages
      where conversation_id = NEW.conversation_id
        and sender_id = auth.uid()
        and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'Too many messages in this chat — slow down and try again in a minute.';
  end if;
  -- (M19) Later-rejected / flagged: no new messages in a chat
  -- where either side is no longer an approved, unflagged
  -- student — EXCEPT (M20 D-1) a plain text message coordinating
  -- an order that is already open between these two students.
  -- The exemption is deliberately narrow: kind 'text' ONLY (an
  -- offer is never exempt), the order must be for this
  -- conversation's listing, between these two participants
  -- either way round, and still open (reserved, paid, held,
  -- shipped or delivered). Offers, offer answers, pickup tickets
  -- and agreed prices stay gated — a later-rejected student
  -- cannot start anything new, they can only finish what is
  -- already moving. The blocked check above still applies: a
  -- blocked student cannot message even about an open order.
  select c.buyer_id, c.seller_id, c.listing_id
    into v_buyer, v_seller, v_listing_id
    from public.conversations c
    where c.id = NEW.conversation_id;
  if NEW.kind = 'text'
    and exists (
      select 1 from public.orders o
      where o.listing_id = v_listing_id
        and ((o.buyer_id = v_buyer and o.seller_id = v_seller)
             or (o.buyer_id = v_seller and o.seller_id = v_buyer))
        and o.status in ('reserved', 'paid', 'held', 'shipped', 'delivered')
    ) then
    return NEW;
  end if;
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
-- D-2 + M-16 — insert_notification(): m19/04 live function with ONLY the D-2 prefs bypass ('dispute' always, team 'system') and the M-16 kind-role checks.
-- ---------------------------------------------------------------------------
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
  v_link_order_id uuid;
  v_release_order_id uuid;
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

  -- (M20 M-16) Fake 'system' / 'release' notices: only the team
  -- may send kind 'system'. kind 'release' may be sent by the
  -- team, or by a caller when the order already has a release
  -- leg — the app sends the release notice through notifyUser()
  -- AFTER release_order returns (src/lib/orders.js
  -- finishRelease), so the legs exist by then; auto-release
  -- writes its notices straight to the table and never calls
  -- this function, and release_order itself sends no
  -- notification at all. A matching leg is looked up from
  -- p_order_id first, else from a '/order/<uuid>' link.
  if p_kind = 'system' and not public.pm_is_owner() then
    raise exception 'Only the PulseMarket team can send a system notification.';
  end if;
  if p_kind = 'release' and not public.pm_is_owner() then
    if p_link is not null and p_link ~ '^/order/[0-9a-fA-F-]{36}$' then
      v_link_order_id := substring(p_link from 8)::uuid;
    end if;
    v_release_order_id := coalesce(p_order_id, v_link_order_id);
    if v_release_order_id is null
      or not exists (
        select 1 from public.wallet_ledger
        where order_id = v_release_order_id
          and kind = 'release'
          and bucket = 'held'
      ) then
      raise exception 'A release notification needs a release that already happened.';
    end if;
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
  -- (M20 D-2) Two kinds bypass the gate: 'dispute' always (a
  -- student who switched dispute notices off still hears about a
  -- frozen order), and 'system' when the caller is the team.
  -- Every other kind keeps the gate exactly as before.
  if p_kind <> 'dispute'
    and not (p_kind = 'system' and public.pm_is_owner()) then
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
-- M-10 — pm_validate_conversation_insert(): milestone-17's live function with ONLY the forced agreed_price / snapshot copy / last_message_at.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_conversation_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing public.listings%rowtype;
begin
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
  end if;
  -- (M20 M-10) A new conversation never carries a caller-set agreed
  -- price, snapshot or timestamp: the agreed price starts null (it
  -- is only ever set by an accepted offer, through the
  -- conversation-update trigger), the price / title / label are
  -- copied from the listing, and last_message_at starts at now —
  -- so a false agreed price can never be stored and a far-future
  -- timestamp can never pin a chat at the top of the list.
  select * into v_listing from public.listings where id = NEW.listing_id;
  if not found then
    raise exception 'That listing does not exist.';
  end if;
  NEW.agreed_price := null;
  NEW.listing_price := v_listing.price;
  NEW.listing_title := v_listing.title;
  NEW.seller_label := v_listing.seller_label;
  NEW.last_message_at := now();
  if not exists (
    select 1 from public.verifications
    where user_id = NEW.buyer_id
      and status = 'approved'
  ) or not exists (
    select 1 from public.verifications
    where user_id = NEW.seller_id
      and status = 'approved'
  ) then
    raise exception 'Only approved students can chat — verification must be approved first.';
  end if;
  if exists (
    select 1 from public.verifications
    where user_id in (NEW.buyer_id, NEW.seller_id) and flagged
  ) then
    raise exception 'This account is under review — new chats are paused.';
  end if;
  if exists (
    select 1 from public.blocked_users
    where (blocker_id = NEW.buyer_id and blocked_id = NEW.seller_id)
       or (blocker_id = NEW.seller_id and blocked_id = NEW.buyer_id)
  ) then
    raise exception 'You cannot start a chat with this student.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_conversation_insert_trg on public.conversations;
create trigger pm_validate_conversation_insert_trg
  before insert on public.conversations
  for each row execute function public.pm_validate_conversation_insert();

-- ---------------------------------------------------------------------------
-- M-10 (update half) — pm_validate_conversation_update(): m19/01 live function (agreed-price gate untouched) with ONLY the last_message_at rule added.
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
  -- (M20 M-10) last_message_at may only move forward to about now.
  -- A far-future value would pin the chat at the top of the list
  -- and a backwards value would bury it. Five minutes of slack
  -- covers a phone clock running fast.
  if NEW.last_message_at is distinct from OLD.last_message_at then
    if NEW.last_message_at is null
      or NEW.last_message_at < coalesce(OLD.last_message_at, NEW.last_message_at)
      or NEW.last_message_at > now() + interval '5 minutes' then
      raise exception 'last_message_at can only move to now.';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_conversation_update_trg on public.conversations;
create trigger pm_validate_conversation_update_trg
  before update on public.conversations
  for each row execute function public.pm_validate_conversation_update();

-- ---------------------------------------------------------------------------
-- M-8 + M-25 — ratings insert policy: milestone-11's policy with ONLY the order's-listing check and the cash-delivered widening.
-- ---------------------------------------------------------------------------
drop policy if exists "Buyers rate their released orders" on public.ratings;
create policy "Buyers rate their released orders"
  on public.ratings for insert
  with check (
    auth.uid() = rater_id
    and exists (
      select 1
      from public.orders o
      where o.id = order_id
        and o.buyer_id = auth.uid()
        and o.seller_id = rated_id
        -- (M20 M-25) Cash orders end at 'delivered' — they never
        -- reach 'released' — so a delivered cash order can be
        -- rated too. Held orders still need 'released'.
        and (o.status = 'released'
             or (o.payment_method = 'cash' and o.status = 'delivered'))
    )
    -- (M20 M-8) The rating must attach to the rated order's own
    -- listing (or to no listing). Written as a scalar subquery on
    -- purpose: inside the EXISTS above, an unqualified listing_id
    -- would resolve to the ORDER's listing_id (orders has that
    -- column), which would make the check trivially true.
    and (listing_id is null
         or listing_id = (select o2.listing_id from public.orders o2 where o2.id = order_id))
  );

-- ---------------------------------------------------------------------------
-- M-22 + M-23 — pm_validate_order_insert(): milestone-17's live function with ONLY the courier-tier mirror and the agreed-price acceptance.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_order_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_listing public.listings%rowtype;
  v_service integer;
  v_secure integer;
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.status is distinct from 'reserved' then
    raise exception 'A new order always starts as reserved.';
  end if;
  if NEW.buyer_id is distinct from auth.uid() then
    raise exception 'An order can only be placed as yourself.';
  end if;
  if NEW.buyer_id = NEW.seller_id then
    raise exception 'You cannot buy your own listing.';
  end if;
  if NEW.seller_code is not null then
    raise exception 'Seller codes are stored in the handoff table, not on the order.';
  end if;
  if NEW.delivery_pin is not null then
    raise exception 'A new order has no delivery PIN yet.';
  end if;
  if coalesce(NEW.frozen, false) then
    raise exception 'A new order is never frozen.';
  end if;
  if coalesce(NEW.code_attempts, 0) <> 0
    or coalesce(NEW.handoff_locked, false)
    or NEW.handoff_scanned_at is not null
    or NEW.handoff_photo_buyer is not null
    or NEW.handoff_photo_seller is not null
    or coalesce(NEW.buyer_confirmed, false)
    or coalesce(NEW.seller_confirmed, false)
    or coalesce(NEW.shipping_advance_released, false)
    or NEW.return_status is not null
    or NEW.paid_at is not null
    or NEW.held_at is not null
    or NEW.delivered_at is not null
    or NEW.released_at is not null
  then
    raise exception 'A new order cannot already carry handoff, shipping or payment history.';
  end if;

  -- Lock the listing row: two buyers reserving the same item at the
  -- same time now queue here instead of both reading it 'active'.
  -- (The partial unique index in Milestone 15 section 5 is the
  -- backstop — it refuses a second open order for the listing even
  -- if the lock were ever bypassed.)
  select * into v_listing from public.listings where id = NEW.listing_id for update;
  if not found then
    raise exception 'That listing does not exist.';
  end if;
  if v_listing.status <> 'active' then
    raise exception 'This item is no longer available.';
  end if;
  if v_listing.seller_id <> NEW.seller_id then
    raise exception 'That listing belongs to a different seller.';
  end if;

  -- (DB-5) Only a verified, unflagged student can place an order.
  -- The app requires verification before checkout; a direct API
  -- call could otherwise order with no verification row at all.
  if not exists (
    select 1 from public.verifications
    where user_id = NEW.buyer_id
      and status = 'approved'
  ) then
    raise exception 'Only approved students can place an order — verification must be approved first.';
  end if;
  if exists (
    select 1 from public.verifications
    where user_id = NEW.buyer_id and coalesce(flagged, false)
  ) then
    raise exception 'This account is flagged and cannot place orders.';
  end if;

  -- (A c6) Cash is paid face to face, so a cash order can never
  -- ship — shipping proof needs status 'held', which a cash order
  -- never reaches. The app refuses this too; the database is the
  -- backstop.
  if NEW.payment_method = 'cash' and NEW.delivery_method = 'shipping' then
    raise exception 'Cash is paid face to face — choose meet in person.';
  end if;
  -- (M20 M-23) The agreed price is honoured: an item_price
  -- equal to the conversation's agreed_price is accepted when a
  -- conversation exists for this buyer and listing with that
  -- price agreed (0 < agreed <= listing price — the conversation
  -- update trigger already guarantees an agreed price only ever
  -- comes from an accepted offer). Fees below are re-derived
  -- from NEW.item_price, so no fee change is needed.
  if NEW.item_price <> v_listing.price
    and not exists (
      select 1 from public.conversations c
      where c.buyer_id = NEW.buyer_id
        and c.seller_id = NEW.seller_id
        and c.listing_id = NEW.listing_id
        and c.agreed_price = NEW.item_price
        and c.agreed_price > 0
        and c.agreed_price <= v_listing.price
    ) then
    raise exception 'The order price must match the listing price or the price you agreed with the seller.';
  end if;

  -- (F8) The delivery method must be one this listing offers, and a
  -- same_state listing never leaves the seller's state.
  if cardinality(v_listing.delivery_methods) > 0
    and not (NEW.delivery_method = any(v_listing.delivery_methods)) then
    raise exception 'This seller does not offer that delivery method for this item.';
  end if;
  if v_listing.ships_to = 'same_state'
    and NEW.delivery_method = 'shipping'
    and NEW.ship_to_state is distinct from v_listing.state then
    raise exception 'This item only ships within the seller''s state.';
  end if;

  -- Fees, mirroring feeBreakdown: cash (or a free item) has no fees;
  -- held orders pay 5% (flat 150 under 5000, capped at 2000) plus
  -- 1.5% + 100 secure fee.
  if NEW.payment_method = 'cash' or NEW.item_price = 0 then
    v_service := 0;
    v_secure := 0;
  else
    v_service := case
      when NEW.item_price < 5000 then 150
      else least(round(NEW.item_price * 0.05)::integer, 2000)
    end;
    v_secure := round(NEW.item_price * 0.015)::integer + 100;
  end if;
  if NEW.service_fee <> v_service or NEW.secure_fee <> v_secure then
    raise exception 'The fees on this order do not match the PulseMarket fee rules.';
  end if;
  if NEW.total <> NEW.item_price + NEW.service_fee + NEW.secure_fee + NEW.shipping_fee then
    raise exception 'The order total does not add up.';
  end if;

  if NEW.delivery_method = 'meetup' then
    if NEW.shipping_fee <> 0 then
      raise exception 'A meet-in-person order has no shipping fee.';
    end if;
    if NEW.meetup_spot is null or btrim(NEW.meetup_spot) = '' then
      raise exception 'Choose a safe meetup spot.';
    end if;
    -- (DB-5) The spot must be one of the app's safe meetup spots,
    -- not any string the caller invents.
    if NEW.meetup_spot not in ('University main gate', 'Student centre / SUG building', 'Campus library entrance', 'Faculty building lobby', 'Hostel common area (daytime)') then
      raise exception 'Choose a safe meetup spot from the list.';
    end if;
    if NEW.courier is not null then
      raise exception 'A meet-in-person order has no courier.';
    end if;
  elsif NEW.delivery_method = 'shipping' then
    -- The fee is priced from the ship-to state, not the buyer's
    -- university state: the parcel goes where ship_to_state says.
    if NEW.shipping_fee <> public.pm_shipping_fee(v_listing.state, NEW.ship_to_state) then
      raise exception 'The shipping fee does not match the zone for the state to ship to.';
    end if;
    if NEW.ship_to_state is null or btrim(NEW.ship_to_state) = '' then
      raise exception 'Choose the state to ship to.';
    end if;
    if NEW.courier is null
      or NEW.courier not in ('GIG Logistics', 'GUO Transport', 'Chowdeck Relay', 'Peace Logistics', 'ABC Transport', 'DHL Domestic', 'Bus Park Waybill') then
      raise exception 'Choose a courier for this shipment.';
    end if;
    -- (M20 M-22) Courier tiers, mirroring createOrder in
    -- src/lib/orders.js: an interstate shipment (ship-to state
    -- different from the seller's state) over 20,000 naira
    -- travels with GIG Logistics or GUO Transport only. Bus Park
    -- Waybill stays allowed under 20,000, and same-city shipping
    -- is untouched (Chowdeck Relay is same-city only).
    if NEW.ship_to_state is distinct from v_listing.state
      and NEW.item_price > 20000
      and NEW.courier not in ('GIG Logistics', 'GUO Transport') then
      raise exception 'An item over ₦20,000 shipping to another state must travel with GIG Logistics or GUO Transport.';
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_order_insert_trg on public.orders;
create trigger pm_validate_order_insert_trg
  before insert on public.orders
  for each row execute function public.pm_validate_order_insert();

-- ---------------------------------------------------------------------------
-- §12) M-24 — respond_offer(): answer an offer in ONE database move.
-- The legacy app path flips the offer, then sets (or clears)
-- conversations.agreed_price in a second write — if the second write
-- fails, an accepted offer ends up with no agreed price and no way
-- to retry (the offer is no longer pending). This RPC does both
-- writes in a single transaction, under a row lock, so two racing
-- answers cannot both land. The app calls it first and falls back
-- to the legacy two-step path only when the RPC does not exist yet
-- (PGRST202/42883). Offer answers stay gated: a later-rejected or
-- flagged student cannot answer (the D-1 exemption is for plain
-- messages only — it does NOT apply here), and a blocked student
-- cannot answer either. The message-update trigger re-validates
-- all of this; the checks below give plain errors before any
-- write, and the FOR UPDATE lock closes the race.
-- ---------------------------------------------------------------------------
create or replace function public.respond_offer(p_message_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_msg public.messages%rowtype;
  v_buyer uuid;
  v_seller uuid;
begin
  if p_message_id is null then
    raise exception 'An answer needs an offer.';
  end if;
  if p_status not in ('accepted', 'declined') then
    raise exception 'An offer can only be accepted or declined.';
  end if;
  if v_caller is null then
    raise exception 'Sign in to answer this offer.';
  end if;

  -- Lock the message row first: concurrent answers queue here, so
  -- only the first one sees 'pending'.
  select * into v_msg
  from public.messages
  where id = p_message_id
  for update;

  if not found then
    raise exception 'Offer not found.';
  end if;
  if v_msg.kind <> 'offer' then
    raise exception 'Only an offer can be accepted or declined.';
  end if;
  if coalesce(v_msg.offer_status, '') <> 'pending' then
    raise exception 'This offer was already answered.';
  end if;
  if v_msg.offer_amount is null then
    raise exception 'This offer has no amount to accept or decline.';
  end if;

  select buyer_id, seller_id into v_buyer, v_seller
  from public.conversations
  where id = v_msg.conversation_id;

  if v_buyer is null then
    raise exception 'That offer has no conversation.';
  end if;
  if v_caller <> v_buyer and v_caller <> v_seller then
    raise exception 'Only a participant of this chat can answer an offer.';
  end if;
  if v_caller = v_msg.sender_id then
    raise exception 'You cannot accept or decline your own offer.';
  end if;
  -- Blocked students cannot answer offers (M18 §10, same rule as
  -- the message-update trigger).
  if exists (
    select 1 from public.blocked_users b
    where (b.blocker_id = v_buyer and b.blocked_id = v_seller)
       or (b.blocker_id = v_seller and b.blocked_id = v_buyer)
  ) then
    raise exception 'You cannot answer an offer in a chat with a blocked student.';
  end if;
  -- Offer answers stay gated even when the chat has an open order
  -- (D-1 exempts plain messages only).
  if not public.pm_chat_verification_ok(v_buyer, v_seller) then
    raise exception 'You cannot answer this offer — one of the students in this chat is no longer verified.';
  end if;

  -- Flip the offer first: the conversation-update trigger requires
  -- a matching accepted offer before it lets the agreed price move.
  update public.messages
  set offer_status = p_status
  where id = v_msg.id;

  if p_status = 'accepted' then
    update public.conversations
    set agreed_price = v_msg.offer_amount
    where id = v_msg.conversation_id;
  end if;
  -- A decline flips the message only (above). A pending offer never
  -- set the agreed price, so nothing is cleared: an agreed price
  -- equal to this amount belongs to a different, still-valid accepted
  -- offer and must stay. Clearing it here would raise 'An agreed
  -- price cannot be removed.' from the conversation trigger and roll
  -- the whole answer back, stranding the offer as pending forever.
end;
$$;

revoke execute on function public.respond_offer(uuid, text) from public;
grant execute on function public.respond_offer(uuid, text) to authenticated;

-- Done. Milestone 20 core SQL (supabase/m20/01-core.sql).

-- ===========================================================================
-- PulseMarket — Milestone 20, file 02: SQL HARDENING (M-2, M-6, M-9, M-11,
-- M-12, M-14, M-15, M-17, M-19, M-20, M-21).
--
-- DEPLOY ORDER: push the M20 app code FIRST, then run this file ONCE in
-- the Supabase SQL Editor. NEVER re-run milestone-14/15/16/17/18/19.sql
-- after it, and NEVER re-run milestone-17.sql as-is (its grandfather
-- UPDATE would mass-approve pending students). Every statement in this
-- file is idempotent (CREATE ... IF NOT EXISTS, DROP ... IF EXISTS,
-- CREATE OR REPLACE, guarded DO blocks), so a re-run of THIS file is
-- safe — but run it once and check the result.
--
-- SCOPE: this file is the hardening worker's half of Milestone 20. It
-- does NOT reproduce any function owned by the core worker
-- (pm_validate_listing_update, pm_validate_message_insert/update,
-- pm_validate_pickup_insert/update, pm_validate_conversation_insert/
-- update, insert_notification, pm_validate_ledger_insert,
-- pm_validate_order_update, pm_validate_dispute_insert, release_order,
-- auto_release_overdue_orders, review_verification,
-- resubmit_verification, pm_validate_listing_insert, the order-insert
-- trigger, the ratings policy). Where a new check lands on a table one
-- of those functions already guards, it is a SEPARATE narrow trigger
-- here, never a copy of the core worker's function. Draft section (G)
-- open questions are NOT implemented here.
--
-- CORRECTIONS TO THE TASK TEXT (verified against the repo, not assumed):
--   * The listing boost columns are boost_tier / boosted_until
--     (supabase/milestone-3-4.sql:74-75), not "boost_until". This file
--     uses boosted_until throughout.
--   * The checkpoint status enum has NO 'in_transit' value. The real
--     enum (supabase/milestone-8.sql:83-90) is: picked_up,
--     left_origin, stopped, arrived_terminal, out_for_delivery,
--     ready_for_pickup, delivered. M-12 ranks them in that order.
--   * The checkpoint photo column is `photo` (milestone-8.sql:83-90),
--     not photo_url.
--
-- KNOWN GAP — M-5 (NO SQL in this file): evidence "verified" cannot be
-- fixed in SQL. duration_seconds is caller-supplied and the database
-- cannot measure a video. The app already measures duration from the
-- file itself (src/lib/evidence.js) and refuses unmeasurable clips.
-- Until a server-side measurement (Edge Function / storage webhook
-- with ffprobe) exists, treat `verified` as advisory: the team
-- spot-checks unboxing videos before releasing money.
--
-- COUPLINGS — read before running (each needs its app half in the
-- same release, code first, then this SQL):
--   * M-2: after this file runs, the app's current boostListing()
--     (src/lib/listings.js) — a direct seller update of
--     boost_tier/boosted_until — will be REFUSED by the narrow guard
--     trigger in §1. The app must call purchase_boost() instead, and
--     the TEAM must confirm each payment by setting the
--     boost_purchases row to 'paid' (Admin UI or SQL Editor — no
--     admin UI for this exists yet; that is a follow-up, not SQL).
--     Until the team confirms, a purchase stays 'pending_payment'
--     and no boost is applied.
--   * M-6: after this file runs, getPublicUrl() links for
--     evidence-media stop working (bucket is private). The app must
--     mint short-lived signed URLs (createSignedUrl) for evidence
--     viewing in the same release, or buyers/sellers will see broken
--     handoff / waybill / unboxing media. Signed URLs are checked
--     against the same SELECT policy in §2.
--   * M-19: bump_listing_view() is ready here, but the app does not
--     call it yet — view counts keep working exactly as before
--     (participant-only +1 via the existing trigger) until the app
--     adopts the RPC.
--
-- DIFF VERIFICATION (every reproduced function was read in full and
-- diffed; only the documented change differs):
--   * M-12 pm_validate_checkpoint_insert: reproduced from
--     supabase/milestone-16.sql:1671-1697. ONLY additions: the
--     delivered-gate, the monotonic-rank check, the no-repeat-
--     delivered check, and the checkpoint-photo URL check (all
--     marked "(M20)" below).
--   * M-15 count_referrals: reproduced from
--     supabase/milestone-11.sql:110-122. ONLY change: it now reads
--     the caller's own invite code from their verification row and
--     counts that code; a passed code that is not their own raises.
--     Same signature (count_referrals(text)), same REVOKE/GRANT.
--   * M-17: the partial unique index disputes_one_open_per_order_idx
--     ALREADY EXISTS — milestone-16.sql §19 (lines 1930-1947)
--     created it with the same duplicate guard. §8 below repeats
--     that guarded block verbatim, so on this database it is a
--     no-op; it only creates the index if a database somehow lacks
--     it and has no duplicate open reports.
--   * M-14 pm_has_verified_unboxing: NOT reproduced — only its
--     grants change (§6). Verified by grep: milestone-14.sql:263-288
--     defines it with no REVOKE/GRANT anywhere.
-- ===========================================================================

-- ===========================================================================
-- §1) M-2 — Free boost forever, closed. A boost now needs a payment
--    record: the seller buys through purchase_boost(), the team
--    confirms payment by flipping the row to 'paid', and ONLY that
--    flip sets the listing's boost. A seller can no longer self-grant
--    a boost by direct API (the narrow guard trigger below refuses
--    any boost_tier/boosted_until change by a non-team caller).
--
--    DELIBERATE DEVIATION from the literal task text, documented:
--    the task says "no existing pending/paid purchase for that
--    listing". A 'paid' row is the PERMANENT payment record — it is
--    never deleted — so blocking on ANY paid row would let a seller
--    boost a listing exactly once, ever, and never re-boost it after
--    the 24h/72h expires. Instead purchase_boost() refuses (a) any
--    still-pending purchase for the listing, and (b) a new purchase
--    while the listing's current boost is still live. A paid,
--    expired boost does not block the next purchase. The payment
--    record itself stays as the audit trail.
-- ===========================================================================

create table if not exists public.boost_purchases (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  seller_id uuid not null references auth.users (id) on delete cascade,
  tier integer not null check (tier in (500, 1000)),
  status text not null default 'pending_payment'
    check (status in ('pending_payment', 'paid', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists boost_purchases_listing_idx
  on public.boost_purchases (listing_id);

-- One unpaid purchase per listing at a time (race-safe backstop for
-- the check inside purchase_boost()). Deliberately NOT extended to
-- 'paid' rows: a paid row is the permanent payment record, and a
-- seller must be able to buy the NEXT boost after one expires.
create unique index if not exists boost_purchases_one_pending_idx
  on public.boost_purchases (listing_id) where status = 'pending_payment';

alter table public.boost_purchases enable row level security;

drop policy if exists "Sellers insert their own boost purchases" on public.boost_purchases;
create policy "Sellers insert their own boost purchases"
  on public.boost_purchases for insert
  with check (seller_id = auth.uid());

drop policy if exists "Sellers read their own boost purchases" on public.boost_purchases;
create policy "Sellers read their own boost purchases"
  on public.boost_purchases for select
  using (seller_id = auth.uid());

drop policy if exists "Team reads all boost purchases" on public.boost_purchases;
create policy "Team reads all boost purchases"
  on public.boost_purchases for select
  using (public.pm_is_owner());

-- The team confirms (or cancels) payment. Sellers get NO update
-- policy: a seller must never flip their own row to 'paid'.
drop policy if exists "Team updates all boost purchases" on public.boost_purchases;
create policy "Team updates all boost purchases"
  on public.boost_purchases for update
  using (public.pm_is_owner())
  with check (public.pm_is_owner());

-- Keep updated_at honest on every status change.
create or replace function public.pm_touch_boost_purchase()
returns trigger
language plpgsql
as $$
begin
  NEW.updated_at = now();
  return NEW;
end;
$$;

drop trigger if exists pm_touch_boost_purchase_trg on public.boost_purchases;
create trigger pm_touch_boost_purchase_trg
  before update on public.boost_purchases
  for each row execute function public.pm_touch_boost_purchase();

create or replace function public.purchase_boost(p_listing_id uuid, p_tier integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seller uuid;
  v_status text;
  v_boosted_until timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Sign in first to boost a listing.';
  end if;
  if p_listing_id is null then
    raise exception 'A boost needs a listing.';
  end if;
  if p_tier is null or p_tier not in (500, 1000) then
    raise exception 'Choose a boost tier: 500 or 1000.';
  end if;
  select seller_id, status, boosted_until
    into v_seller, v_status, v_boosted_until
    from public.listings
    where id = p_listing_id;
  if not found then
    raise exception 'That listing does not exist.';
  end if;
  if v_seller <> auth.uid() then
    raise exception 'Only the seller can boost this listing.';
  end if;
  if v_status <> 'active' then
    raise exception 'Only an active listing can be boosted.';
  end if;
  if exists (
    select 1 from public.boost_purchases
    where listing_id = p_listing_id
      and status = 'pending_payment'
  ) then
    raise exception 'This listing already has a boost waiting for payment — pay for that one or ask the team to cancel it first.';
  end if;
  -- A paid, expired boost does not block the next purchase (see
  -- the deviation note in the §1 header); a still-live boost does.
  if v_boosted_until is not null and v_boosted_until > now() then
    raise exception 'This listing is already boosted.';
  end if;
  insert into public.boost_purchases (listing_id, seller_id, tier)
  values (p_listing_id, auth.uid(), p_tier);
end;
$$;

revoke execute on function public.purchase_boost(uuid, integer) from public;
grant execute on function public.purchase_boost(uuid, integer) to authenticated;

-- When the team confirms payment, the listing gets its boost.
-- SECURITY DEFINER, so the listing update inside it is not stopped
-- by the listings UPDATE RLS.
create or replace function public.pm_apply_paid_boost()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status = 'paid' and OLD.status is distinct from 'paid' then
    update public.listings
      set boost_tier = NEW.tier,
          boosted_until = case
            when NEW.tier = 500 then now() + interval '24 hours'
            else now() + interval '72 hours'
          end
      where id = NEW.listing_id;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_apply_paid_boost_trg on public.boost_purchases;
create trigger pm_apply_paid_boost_trg
  after update on public.boost_purchases
  for each row execute function public.pm_apply_paid_boost();

-- NARROW guard (separate from the core worker's
-- pm_validate_listing_update — this trigger checks ONLY the boost
-- columns, nothing else). Any change to boost_tier/boosted_until by
-- a non-team caller is refused, so the free-boost direct-API path
-- is closed. Clearing a boost is a team action too.
--
-- WHY the paid-boost path still passes this guard: the trigger on
-- boost_purchases runs inside the team confirmer's transaction, so
-- auth.uid() here is still the team user and pm_is_owner() is true
-- (pm_is_owner() reads the caller's JWT email, which a SECURITY
-- DEFINER function does not change). If the team confirms from the
-- SQL Editor instead, auth.uid() is null and the trigger steps
-- aside — the same SQL-Editor bypass every other trigger in this
-- codebase uses (e.g. milestone-16.sql pm_validate_checkpoint_insert
-- and pm_validate_listing_update).
create or replace function public.pm_guard_listing_boost()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.boost_tier is distinct from OLD.boost_tier
    or NEW.boosted_until is distinct from OLD.boosted_until then
    if not public.pm_is_owner() then
      raise exception 'A boost can only be set after payment — buy a boost and the PulseMarket team confirms it.';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_guard_listing_boost_trg on public.listings;
create trigger pm_guard_listing_boost_trg
  before update on public.listings
  for each row execute function public.pm_guard_listing_boost();

-- ===========================================================================
-- §2) M-6 — evidence-media bucket goes private. Milestone 7 created it
--    public with an "Anyone reads evidence media" policy, so anyone —
--    including anonymous callers — could read and enumerate every
--    handoff photo, unboxing video and waybill/receipt photo, which
--    carry real names, addresses and phone numbers. The bucket is now
--    private and reads go through pm_evidence_object_readable():
--    the team, the uploader, or a buyer/seller of an order the file
--    belongs to. Upload/update/delete policies for own-folder writes
--    are left as they are (except the handoff UPDATE policy, dropped
--    in §3 for M-9).
--
--    VERIFIED against the app's stored URL formats (all three libs
--    store the getPublicUrl() result, i.e.
--    https://<project>.supabase.co/storage/v1/object/public/
--    evidence-media/<path>):
--      evidence.js   <uid>/evidence-<orderId>-<kind>-<ts>.<ext>
--      handoff.js    <uid>/handoff-<orderId>-<role>-<ts>.jpg
--      shipping.js   <uid>/shipping/<orderId>-<label>-<ts>.jpg
--    The helper matches a stored URL by exact suffix: the URL must
--    contain '/evidence-media/<object path>' AND end with the object
--    path, so one file's name can never match another file's URL by
--    prefix. It also accepts a bare stored path (url = object name)
--    in case the app ever stores paths instead of URLs.
--    Signed URLs minted by the app are checked against this same
--    SELECT policy by Supabase, so the app's switch to signed URLs
--    (same release) keeps working and anonymous holders of an old
--    public link get nothing.
-- ===========================================================================

update storage.buckets set public = false where id = 'evidence-media';

create or replace function public.pm_evidence_object_readable(p_object_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    -- The PulseMarket team reads everything (same check as
    -- pm_is_owner(): the caller's JWT email).
    public.pm_is_owner()
    -- The uploader: the object path starts with their own uid folder.
    or split_part(p_object_name, '/', 1) = auth.uid()::text
    -- A participant of the order an evidence row belongs to. The
    -- stored URL (evidence.url) must be this exact object.
    or exists (
      select 1
      from public.evidence e
      join public.orders o on o.id = e.order_id
      where (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
        and (
          e.url = p_object_name
          or (
            e.url like '%/evidence-media/' || p_object_name
            and right(e.url, length(p_object_name)) = p_object_name
          )
        )
    )
    -- A participant of the order a photo column points at: handoff
    -- photos, waybill photo, receipt photo (orders table).
    or exists (
      select 1
      from public.orders o
      where (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
        and (
          (o.handoff_photo_buyer is not null
            and (o.handoff_photo_buyer = p_object_name
              or (o.handoff_photo_buyer like '%/evidence-media/' || p_object_name
                and right(o.handoff_photo_buyer, length(p_object_name)) = p_object_name)))
          or (o.handoff_photo_seller is not null
            and (o.handoff_photo_seller = p_object_name
              or (o.handoff_photo_seller like '%/evidence-media/' || p_object_name
                and right(o.handoff_photo_seller, length(p_object_name)) = p_object_name)))
          or (o.waybill_photo is not null
            and (o.waybill_photo = p_object_name
              or (o.waybill_photo like '%/evidence-media/' || p_object_name
                and right(o.waybill_photo, length(p_object_name)) = p_object_name)))
          or (o.receipt_photo is not null
            and (o.receipt_photo = p_object_name
              or (o.receipt_photo like '%/evidence-media/' || p_object_name
                and right(o.receipt_photo, length(p_object_name)) = p_object_name)))
        )
    )
    -- A participant of the order a checkpoint photo belongs to.
    or exists (
      select 1
      from public.shipping_checkpoints c
      join public.orders o on o.id = c.order_id
      where (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
        and c.photo is not null
        and (
          c.photo = p_object_name
          or (
            c.photo like '%/evidence-media/' || p_object_name
            and right(c.photo, length(p_object_name)) = p_object_name
          )
        )
    ),
    false
  );
$$;

-- The public read goes. No anonymous or stranger read remains.
drop policy if exists "Anyone reads evidence media" on storage.objects;
create policy "Order participants and team read evidence media"
  on storage.objects for select
  using (
    bucket_id = 'evidence-media'
    and public.pm_evidence_object_readable(name)
  );

-- ===========================================================================
-- §3) M-9 — Handoff photo bytes can no longer be swapped after
--    confirming. Milestone 15 §E already dropped EVERY UPDATE policy
--    on storage.objects mentioning evidence-media (including the
--    Milestone 7 "Students replace their own evidence media"
--    policy). Milestone 16 §12 then restored exactly ONE narrow
--    policy for handoff retakes:
--      "Students replace their own handoff photos"
--      (own folder AND name like '<uid>/handoff-%')
--    That policy covers ONLY handoff paths, so per the task it is
--    DROPPED outright (narrowing would only be needed if it covered
--    more). The app half is already done: handoff.js now writes a
--    timestamped path with upsert:false, so no legitimate flow needs
--    a same-path replace. After this drop, NO UPDATE policy on
--    storage.objects mentions evidence-media at all — a verified
--    evidence file cannot be overwritten by direct API either.
-- ===========================================================================

drop policy if exists "Students replace their own handoff photos" on storage.objects;

-- ===========================================================================
-- §4) M-11 — Listing insert has no server-side value validation.
--    A direct API call could publish a ₦0 or ₦999,999,999 listing, a
--    fake university/state, zero photos, or junk delivery_methods
--    (an empty array also defeats the M17 order-insert
--    delivery-method check). This is a SEPARATE narrow trigger that
--    checks ONLY values — it does NOT reproduce the core worker's
--    pm_validate_listing_insert (identity/approval checks) or
--    pm_validate_listing_update (status allowlist). Lists copied
--    exactly from src/lib/data.js (UNIVERSITIES, CATEGORIES,
--    CONDITIONS) and src/lib/listings.js (checkListingValues:
--    price 1–50,000,000, 1–4 photos, delivery_methods exactly one
--    of ['meetup'] / ['shipping']).
--
--    The BEFORE UPDATE trigger only fires when a value column
--    changes (WHEN clause), and the function only validates a column
--    that actually changed — so an old row with a stale value is
--    never blocked from an unrelated edit. Like every other trigger
--    in this codebase, a call with no signed-in user (SQL Editor)
--    steps aside so the team can correct a row by hand.
-- ===========================================================================

create or replace function public.pm_validate_listing_values()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_expected_state text;
begin
  if auth.uid() is null then
    return NEW;
  end if;

  if TG_OP = 'INSERT' or NEW.price is distinct from OLD.price then
    if NEW.price is null or NEW.price < 1 or NEW.price > 50000000 then
      raise exception 'Price must be between ₦1 and ₦50,000,000.';
    end if;
  end if;

  if TG_OP = 'INSERT'
    or NEW.university is distinct from OLD.university
    or NEW.state is distinct from OLD.state then
    -- University -> state, copied exactly from UNIVERSITIES in
    -- src/lib/data.js (universityState() is the app-side mirror).
    v_expected_state := case NEW.university
      when 'University of Port Harcourt' then 'Rivers'
      when 'University of Lagos' then 'Lagos'
      when 'University of Ibadan' then 'Oyo'
      when 'Obafemi Awolowo University' then 'Osun'
      when 'University of Nigeria, Nsukka' then 'Enugu'
      when 'Ahmadu Bello University' then 'Kaduna'
      when 'University of Benin' then 'Edo'
      when 'University of Ilorin' then 'Kwara'
      when 'Lagos State University' then 'Lagos'
      when 'Federal University of Technology, Akure' then 'Ondo'
      when 'Federal University of Technology, Owerri' then 'Imo'
      when 'Federal University of Technology, Minna' then 'Niger'
      when 'Nnamdi Azikiwe University' then 'Anambra'
      when 'University of Calabar' then 'Cross River'
      when 'University of Jos' then 'Plateau'
      when 'Bayero University Kano' then 'Kano'
      when 'Rivers State University' then 'Rivers'
      when 'Delta State University' then 'Delta'
      when 'Enugu State University of Science and Technology' then 'Enugu'
      when 'Covenant University' then 'Ogun'
      else null
    end;
    if v_expected_state is null then
      raise exception 'Choose your university from the list.';
    end if;
    if NEW.state is distinct from v_expected_state then
      raise exception 'The state does not match that university.';
    end if;
  end if;

  if TG_OP = 'INSERT' or NEW.photos is distinct from OLD.photos then
    if NEW.photos is null
      or array_length(NEW.photos, 1) is null
      or array_length(NEW.photos, 1) < 1
      or array_length(NEW.photos, 1) > 4 then
      raise exception 'A listing needs 1 to 4 photos.';
    end if;
    if exists (
      select 1 from unnest(NEW.photos) p where p is null or btrim(p) = ''
    ) then
      raise exception 'A listing needs 1 to 4 photos.';
    end if;
  end if;

  if TG_OP = 'INSERT' or NEW.delivery_methods is distinct from OLD.delivery_methods then
    if NEW.delivery_methods is distinct from array['meetup']::text[]
      and NEW.delivery_methods is distinct from array['shipping']::text[] then
      raise exception 'Choose how the buyer gets it: meet in person or shipping.';
    end if;
  end if;

  if TG_OP = 'INSERT' or NEW.category is distinct from OLD.category then
    if NEW.category is null or NEW.category not in (
      'Phones & gadgets', 'Fashion', 'Books & study', 'Electronics',
      'Home & hostel', 'Beauty & care', 'Sports & fitness',
      'Food & snacks', 'Services', 'Tickets', 'Vehicles', 'Other'
    ) then
      raise exception 'Choose a category from the list.';
    end if;
  end if;

  if TG_OP = 'INSERT' or NEW.condition is distinct from OLD.condition then
    if NEW.condition is null or NEW.condition not in (
      'New', 'Like New', 'Good', 'Fair', 'Spoilt'
    ) then
      raise exception 'Choose a condition from the list.';
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_listing_values_trg on public.listings;
create trigger pm_validate_listing_values_trg
  before insert on public.listings
  for each row execute function public.pm_validate_listing_values();

drop trigger if exists pm_validate_listing_values_update_trg on public.listings;
create trigger pm_validate_listing_values_update_trg
  before update on public.listings
  for each row
  when (
    OLD.price is distinct from NEW.price
    or OLD.university is distinct from NEW.university
    or OLD.state is distinct from NEW.state
    or OLD.photos is distinct from NEW.photos
    or OLD.delivery_methods is distinct from NEW.delivery_methods
    or OLD.category is distinct from NEW.category
    or OLD.condition is distinct from NEW.condition
  )
  execute function public.pm_validate_listing_values();

-- ===========================================================================
-- §5) M-12 — Checkpoints. Reproduced from
--    supabase/milestone-16.sql:1671-1697 (pm_validate_checkpoint_insert)
--    with ONLY these additions, each marked "(M20)":
--      (a) a 'delivered' checkpoint is forbidden unless the order
--          itself is 'delivered';
--      (b) monotonic progression: the new checkpoint must not rank
--          below the latest one, and 'delivered' cannot repeat.
--          Rank follows the CHECK-list order in milestone-8.sql
--          (picked_up 1, left_origin 2, stopped 3,
--          arrived_terminal 4, out_for_delivery 5,
--          ready_for_pickup 6, delivered 7). The task text's chain
--          names 'in_transit', which is NOT a value in the enum —
--          there is no such status to rank. Equal ranks are allowed
--          for non-delivered stops (e.g. two 'stopped' updates at
--          different places); only going backwards and repeating
--          'delivered' are refused.
--      (c) a checkpoint photo, when present, must match the caller's
--          own-folder evidence-media URL pattern (same pattern the
--          M14/M15 handoff and waybill checks use).
--    Everything else is byte-identical to the M16 source, including
--    the SQL-Editor/team bypass at the top and the shipped/delivered
--    order gate.
-- ===========================================================================

create or replace function public.pm_validate_checkpoint_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_last_status text;
  v_last_rank integer;
  v_new_rank integer;
begin
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
  end if;
  -- (Milestone 22) Lock the order row: two checkpoints inserted at
  -- once used to both read the same "latest" row and both pass, and
  -- the monotonic check below is only meaningful against a stable
  -- latest row.
  select * into v_order from public.orders where id = NEW.order_id for update;
  if not found then
    raise exception 'That order does not exist.';
  end if;
  if v_order.status not in ('shipped', 'delivered') then
    raise exception 'Checkpoints start once the parcel has shipped.';
  end if;
  -- (M20-a) The buyer must not see "Delivered" on tracking before
  -- the order itself is delivered.
  if NEW.status = 'delivered' and v_order.status <> 'delivered' then
    raise exception 'A checkpoint can only say delivered once the order is delivered.';
  end if;
  -- (M20-b) Monotonic progression against the latest checkpoint.
  select status into v_last_status
    from public.shipping_checkpoints
    where order_id = NEW.order_id
    order by created_at desc, id desc
    limit 1;
  if v_last_status is not null then
    v_last_rank := case v_last_status
      when 'picked_up' then 1
      when 'left_origin' then 2
      when 'stopped' then 3
      when 'arrived_terminal' then 4
      when 'out_for_delivery' then 5
      when 'ready_for_pickup' then 6
      when 'delivered' then 7
      else 0
    end;
    v_new_rank := case NEW.status
      when 'picked_up' then 1
      when 'left_origin' then 2
      when 'stopped' then 3
      when 'arrived_terminal' then 4
      when 'out_for_delivery' then 5
      when 'ready_for_pickup' then 6
      when 'delivered' then 7
      else 0
    end;
    if v_new_rank < v_last_rank then
      raise exception 'Checkpoints cannot go backwards — the last stop was %.', v_last_status;
    end if;
    if NEW.status = 'delivered' and v_last_status = 'delivered' then
      raise exception 'This order already has a delivered checkpoint.';
    end if;
  end if;
  -- (M20-c) A checkpoint photo must be the caller's own upload.
  if NEW.photo is not null
    and NEW.photo not like '%/storage/v1/object/public/evidence-media/' || auth.uid()::text || '/%' then
    raise exception 'The checkpoint photo must be a photo uploaded from this app.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_checkpoint_insert_trg on public.shipping_checkpoints;
create trigger pm_validate_checkpoint_insert_trg
  before insert on public.shipping_checkpoints
  for each row execute function public.pm_validate_checkpoint_insert();

-- ===========================================================================
-- §6) M-14 — pm_has_verified_unboxing() is an unauthenticated
--    SECURITY DEFINER oracle. Milestone 14 (lines 263-288) created it
--    with no REVOKE/GRANT, so anyone with the anon key could learn
--    whether any order has a verified unboxing video, bypassing
--    evidence RLS. The function itself is NOT reproduced — only its
--    grants change. Triggers call it as SECURITY DEFINER, so they
--    need no grant; the app's server-side callers are authenticated.
-- ===========================================================================

revoke execute on function public.pm_has_verified_unboxing(uuid) from public;
grant execute on function public.pm_has_verified_unboxing(uuid) to authenticated;

-- ===========================================================================
-- §7) M-15 — count_referrals() lets any authenticated user probe any
--    invite code. Reproduced from supabase/milestone-11.sql:110-122
--    with ONLY this change: it now reads the caller's OWN invite
--    code from their verification row and counts that code. A passed
--    code that is not the caller's own raises plainly; a null code
--    counts the caller's own (the app's call shape). A caller with
--    no verification row has no code, so the count is 0. Same
--    signature (count_referrals(text)), same REVOKE/GRANT, so the
--    app call in src/lib/ratings.js still works unchanged.
-- ===========================================================================

create or replace function public.count_referrals(p_code text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_own text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first to see your referrals.';
  end if;
  select invite_code into v_own
    from public.verifications
    where user_id = auth.uid();
  if v_own is null then
    return 0;
  end if;
  if p_code is not null and p_code <> v_own then
    raise exception 'You can only count referrals for your own invite code.';
  end if;
  return (
    select count(*)::integer
    from public.verifications
    where referred_by = v_own
  );
end;
$$;

revoke all on function public.count_referrals(text) from public;
grant execute on function public.count_referrals(text) to authenticated;

-- ===========================================================================
-- §8) M-17 — One open dispute per order. Milestone 16 §19 (lines
--    1930-1947) ALREADY created this partial unique index with the
--    same duplicate guard, so on this database the block below is a
--    no-op (CREATE UNIQUE INDEX ... IF NOT EXISTS finds it). It is
--    repeated here verbatim so the file is self-sufficient on a
--    database where M16 §19 was somehow skipped — and so a run with
--    duplicate open reports fails loudly with a notice instead of
--    silently leaving the hole open.
--
--    SKIPPED, with reason: NO explanation/category CHECKs are added
--    here. The dispute-insert trigger (pm_validate_dispute_insert,
--    core worker's — reproduced in the M20 draft §6 from
--    milestone-16.sql:1453-1502) already enforces the category
--    whitelist, the 20–2,000 character explanation, a valid email,
--    the paid/held/shipped/delivered order-status gate and the
--    verified-dispute-evidence requirement. Adding CHECKs for the
--    same rules would double-enforce them: two places to keep in
--    sync, and a future list change in one place would start
--    refusing rows the other place accepts. One enforcement point
--    stays the trigger.
-- ===========================================================================

do $$
begin
  if not exists (
    select 1 from public.disputes d1
    join public.disputes d2
      on d1.order_id = d2.order_id and d1.id < d2.id
    where d1.status in ('open', 'under_review')
      and d2.status in ('open', 'under_review')
  ) then
    create unique index if not exists disputes_one_open_per_order_idx
      on public.disputes (order_id) where status in ('open', 'under_review');
  else
    raise notice 'Skipped disputes_one_open_per_order_idx: duplicate open reports exist — resolve them first.';
  end if;
end $$;

-- ===========================================================================
-- §9) M-19 — View-count bump. The old path is RLS-dead for strangers
--    (the listings UPDATE RLS only permits seller/team/order
--    participants) yet unlimited for participants (the M15 trigger
--    allows views = views + 1 by "anyone"). This RPC is the fix: a
--    SECURITY DEFINER bump with a once-per-user-per-day guard. The
--    listings UPDATE RLS is NOT widened.
--
--    The listing_views table has RLS enabled and NO policies: only
--    this RPC (running as the function owner, which bypasses RLS)
--    can write it, and nobody can read or forge rows through the
--    API. The +1 update inside the RPC passes the existing
--    pm_validate_listing_update views-only branch (views = views + 1
--    with every other column unchanged), and it does not touch the
--    boost columns, so the §1 guard trigger passes it too.
--
--    NOTE: the app does not call this RPC yet — view counts keep
--    working exactly as before until the app adopts it.
-- ===========================================================================

create table if not exists public.listing_views (
  listing_id uuid not null references public.listings (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  viewed_on date not null default current_date,
  primary key (listing_id, user_id, viewed_on)
);

alter table public.listing_views enable row level security;

create or replace function public.bump_listing_view(p_listing_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in first.';
  end if;
  if p_listing_id is null then
    raise exception 'A view needs a listing.';
  end if;
  if not exists (select 1 from public.listings where id = p_listing_id) then
    raise exception 'That listing does not exist.';
  end if;
  -- One counted view per user per listing per day. ON CONFLICT DO
  -- NOTHING leaves FOUND false when the row already exists, so the
  -- bump below runs exactly once per day per viewer.
  insert into public.listing_views (listing_id, user_id, viewed_on)
  values (p_listing_id, auth.uid(), current_date)
  on conflict (listing_id, user_id, viewed_on) do nothing;
  if found then
    update public.listings
      set views = views + 1
      where id = p_listing_id;
  end if;
end;
$$;

revoke execute on function public.bump_listing_view(uuid) from public;
grant execute on function public.bump_listing_view(uuid) to authenticated;

-- ===========================================================================
-- §10) M-20 — security_log can be flooded with fake actions. The
--     M14 insert policy admits any order participant, and nothing
--     validated the action or rate-limited inserts — fake
--     wrong_code / handoff_locked rows could bury the real security
--     events the team reads.
--
--     Whitelist (CHECK constraint, NOT VALID so pre-existing rows
--     never block the migration): every action the code actually
--     writes, verified by grep — server-side in verify_seller_code
--     (milestone-14.sql:232-242 and milestone-15.sql:228-235):
--     'wrong_code', 'handoff_locked'; app-side via logSecurityEvent
--     (src/lib/handoff.js:330, src/lib/disputes.js:235,386,
--     src/lib/orders.js:587,603,680,787): 'handoff_unlocked',
--     'dispute_filed', 'dispute_resolved', 'delivery_blocked',
--     'release_blocked'. Any other action value is refused.
--
--     Rate limit (SECURITY DEFINER trigger, so the count sees all
--     rows past RLS): a caller who already logged more than 20 rows
--     in the last minute is refused. Two exemptions, both deliberate:
--       (a) no signed-in user (SQL Editor / server context) — there
--           is no caller to limit, same bypass as every trigger;
--       (b) 'wrong_code' / 'handoff_locked' — raising inside
--           verify_seller_code() would roll back the attempt count
--           and break the 5-attempt handoff lock (the M14 comment
--           says "never raise here"). Those two are already capped
--           at 5 attempts per order by the lock itself, so exempting
--           them from the rate limit does not reopen the flood.
-- ===========================================================================

do $$
begin
  alter table public.security_log
    add constraint security_log_action_whitelist
    check (action in (
      'wrong_code', 'handoff_locked',
      'delivery_blocked', 'release_blocked', 'handoff_unlocked',
      'dispute_filed', 'dispute_resolved'
    )) not valid;
exception when duplicate_object then
  null;
end $$;

create or replace function public.pm_rate_limit_security_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.action in ('wrong_code', 'handoff_locked') then
    return NEW;
  end if;
  select count(*) into v_count
    from public.security_log
    where user_id = auth.uid()
      and created_at >= now() - interval '1 minute';
  if v_count > 20 then
    raise exception 'Too many security events — wait a minute before logging another.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_rate_limit_security_log_trg on public.security_log;
create trigger pm_rate_limit_security_log_trg
  before insert on public.security_log
  for each row execute function public.pm_rate_limit_security_log();

-- ===========================================================================
-- §11) M-21 — Duplicate invite codes. Milestone 11 (lines 90-102)
--    silently SKIPPED creating the unique index whenever any
--    duplicate existed, with no error or notice — duplicates persist
--    and referral attribution stays ambiguous. This block FAILS
--    LOUDLY instead: if duplicates exist it raises an exception
--    that LISTS them (code + count), so the run stops here and the
--    team fixes the codes by hand first. The index is created only
--    when no duplicates exist.
--
--    This block is LAST on purpose: a duplicate-code failure aborts
--    the rest of the script, so it must not block the hardening
--    above it.
-- ===========================================================================

do $$
declare
  v_dupes text;
begin
  select string_agg(format('%s (x%s)', invite_code, cnt), ', ')
    into v_dupes
    from (
      select invite_code, count(*) as cnt
      from public.verifications
      where invite_code is not null
      group by invite_code
      having count(*) > 1
    ) d;
  if v_dupes is not null then
    raise exception 'Duplicate invite codes exist — fix them before the unique index can be created: %', v_dupes;
  end if;
  create unique index if not exists verifications_invite_code_unique_idx
    on public.verifications (invite_code);
end $$;

-- ===========================================================================
-- End of Milestone 20 file 02 (hardening). Run once, after the M20
-- code push. Verify in the SQL Editor: no error, then spot-check —
-- boost_purchases table exists, evidence-media bucket public=false,
-- "Anyone reads evidence media" policy gone, "Students replace
-- their own handoff photos" policy gone, disputes_one_open_per_order_idx
-- present, verifications_invite_code_unique_idx present (or the §11
-- exception listing the duplicates to fix first).
-- ===========================================================================
