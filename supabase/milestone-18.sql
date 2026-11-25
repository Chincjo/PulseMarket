-- PulseMarket Milestone 18 — FOURTH SWEEP FIXES.
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: every statement
-- below is idempotent (CREATE POLICY after DROP POLICY IF EXISTS,
-- CREATE OR REPLACE, DROP TRIGGER IF EXISTS, CREATE INDEX IF NOT
-- EXISTS), so re-running it changes nothing.
--
-- DEPLOY ORDER:
--   1. Push the Milestone 18 app code first (fourth-sweep fixes:
--      App.jsx server-truth gate, Verify.jsx save ordering, flagged
--      seller listing refusal, Checkout / Dispute / Handoff /
--      Evidence fixes, PIN stripping, waybill checks, cancel and
--      reconcile helpers, pagination cursors).
--   2. Run this file ONLY AFTER supabase/milestone-17.sql is
--      confirmed live (M17 fully live 2026-11-25 ~19:23 WAT).
--   3. NEVER re-run milestone-14/15/16/17.sql after this file:
--      this file REPLACES their verification gates, order-update
--      branches, evidence checks and message-update rules, and
--      re-running one of them would put the old rules back.
--      NEVER re-run milestone-17.sql at all after new signups
--      exist: its grandfather UPDATE would mass-approve every
--      then-pending student without ID review.
--
-- WHAT THIS FILE FIXES (fourth sweep, 2026-11-25):
--   * CRITICAL — the team could never see the pending queue (§1):
--     there was no team-read RLS policy on verifications, so the
--     owner's fetchPendingVerifications() always returned [] and
--     no pending student could ever be approved through the app.
--   * CRITICAL — resubmit was broken (§3): M17's
--     resubmit_verification() required the photo URLs to match
--     '%verification-ids/<uid>/%', but the app stores BARE storage
--     paths ('<uid>/front-<ms>.jpg'), never public URLs — see
--     src/lib/listings.js. Every resubmit was refused, so a
--     rejected student could never resubmit. The check now matches
--     the app's format and verifies the object exists.
--   * ID photos locked down (§§2, 4, 5): approval requires photos
--     on the row; photo URLs can only change through resubmit;
--     new rows must carry both photos in the caller's own folder.
--   * Flagged sellers can no longer trade (§§6–7): listing insert
--     refuses flagged sellers; a new order gate requires the
--     seller approved and unflagged.
--   * Seller / team order cancel (§8): a seller may cancel a
--     reserved order (ghosted buyer); the team may cancel
--     reserved / paid.
--   * Evidence must exist (§9): the URL pattern check now also
--     requires the storage object to exist.
--   * Blocked users cannot answer offers (§10): the
--     message-update trigger now checks blocked status (the
--     app-side check was the only guard and it failed open).
--   * Wallet balances RPC (§11): get_wallet_balances() sums the
--     ledger server-side (app wiring is a follow-up).
--   * One waybill, one order (§12): a waybill number cannot be
--     reused across orders.
--
-- WHAT THIS FILE DOES NOT CHANGE: pm_is_owner() and the owner
-- email (not referenced anywhere in this file — every team check
-- goes through public.pm_is_owner()), the fee rules, the 48-hour
-- rule, the return fault amounts, manual escrow, the identity lock,
-- the held -> released ban, the 48h auto-release, and the M17
-- grandfathering (already done — do not repeat it here).
--
-- THIS FILE HAS NOT BEEN EXECUTED ANYWHERE. There is no Postgres in
-- this VM, so it was verified by re-reading only: every reproduced
-- function was diffed against its source (only the documented
-- changes differ — see the sweep report). Run it in the SQL Editor
-- and re-test: /admin shows pending verifications; a rejected
-- student resubmits and lands back at pending review; a flagged
-- seller cannot post or receive orders; a seller can cancel a
-- reserved order; a reused waybill number is refused; a blocked
-- student cannot answer an offer.
--
-- Run AFTER milestones 3–17.

-- ---------------------------------------------------------------------------
-- 1) Team-read policy on verifications (CRITICAL — H1). The only
--    select policy on this table was "own row only", so the owner's
--    fetchPendingVerifications() always returned [] and the M17
--    review queue was permanently empty. Mirrors the M12 pattern
--    for disputes / security_log, via pm_is_owner().
-- ---------------------------------------------------------------------------
drop policy if exists "Team reads all verifications" on public.verifications;
create policy "Team reads all verifications"
  on public.verifications for select
  using (public.pm_is_owner());

-- ---------------------------------------------------------------------------
-- 2) review_verification: approval requires ID photos (D6).
-- ---------------------------------------------------------------------------
create or replace function public.review_verification(p_user_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
    set status = p_status
    where user_id = p_user_id;
  if not found then
    raise exception 'That student has no verification to review.';
  end if;
end;
$$;

revoke execute on function public.review_verification(uuid, text) from public;
grant execute on function public.review_verification(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) resubmit_verification: match the app's bare-path format (CRITICAL).
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
  -- in section 4 recognises. Set it here, inside the RPC, and
  -- nowhere else: the app cannot set it through PostgREST.
  perform set_config('pulsemarket.verification_resubmit', 'true', true);
  update public.verifications
    set status = 'pending review',
        id_front_url = p_front_url,
        id_back_url = p_back_url
    where user_id = auth.uid();
end;
$$;

revoke execute on function public.resubmit_verification(text, text) from public;
grant execute on function public.resubmit_verification(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4) Verification updates: lock photo URLs outside resubmit (H3).
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
  if v_resubmit then
    if auth.uid() <> OLD.user_id then
      raise exception 'Only the student can resubmit their own verification.';
    end if;
    if OLD.status <> 'rejected' or NEW.status <> 'pending review' then
      raise exception 'A resubmission can only move a rejected verification back to pending review.';
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
    return NEW;
  end if;
  -- (M18) ID photos can only change through resubmit_verification()
  -- (the branch above, which returns early). A direct update that
  -- swaps the photo URLs is refused — otherwise the resubmit RPC's
  -- own-folder check means nothing.
  if NEW.id_front_url is distinct from OLD.id_front_url
    or NEW.id_back_url is distinct from OLD.id_back_url then
    raise exception 'ID photos can only be changed by resubmitting your verification.';
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
-- 5) Verification inserts: new rows must carry both ID photos (H3).
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
  return NEW;
end;
$$;

drop trigger if exists pm_validate_verification_insert_trg on public.verifications;
create trigger pm_validate_verification_insert_trg
  before insert on public.verifications
  for each row execute function public.pm_validate_verification_insert();

-- ---------------------------------------------------------------------------
-- 6) Listing inserts: flagged sellers cannot post (H6).
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_listing_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.seller_id is distinct from auth.uid() then
    raise exception 'A listing can only be posted as yourself.';
  end if;
  if not exists (
    select 1 from public.verifications v
    where v.user_id = NEW.seller_id
      and v.status = 'approved'
  ) then
    raise exception 'Only approved students can post a listing — verification must be approved first.';
  end if;
  -- (M18) A flagged seller cannot post new listings (chat and
  -- orders already refuse flagged accounts).
  if exists (
    select 1 from public.verifications
    where user_id = NEW.seller_id
      and coalesce(flagged, false)
  ) then
    raise exception 'Your account is under review — contact support before posting a new listing.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_listing_insert_trg on public.listings;
create trigger pm_validate_listing_insert_trg
  before insert on public.listings
  for each row execute function public.pm_validate_listing_insert();

-- ---------------------------------------------------------------------------
-- 7) Order inserts, seller side (NEW trigger). M17 section 7 checks
--    only the BUYER's approval / flagged status — a seller whose
--    verification was rejected after they posted, or who is flagged,
--    could still receive new orders. A separate small trigger (not a
--    rewrite of the 160-line M17 function) enforces the seller side.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_order_insert_seller()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
  end if;
  if not exists (
    select 1 from public.verifications
    where user_id = NEW.seller_id
      and status = 'approved'
  ) then
    raise exception 'That seller is not an approved student — this item cannot be ordered.';
  end if;
  if exists (
    select 1 from public.verifications
    where user_id = NEW.seller_id
      and coalesce(flagged, false)
  ) then
    raise exception 'That seller''s account is under review — this item cannot be ordered.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_order_insert_seller_trg on public.orders;
create trigger pm_validate_order_insert_seller_trg
  before insert on public.orders
  for each row execute function public.pm_validate_order_insert_seller();

-- ---------------------------------------------------------------------------
-- 8) Order updates: seller / team cancel branches (a).
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

  -- 11) Rider details: team only (no app flow writes them).
  if (NEW.rider_name is distinct from OLD.rider_name
      or NEW.rider_phone is distinct from OLD.rider_phone)
    and not v_owner then
    raise exception 'Only the PulseMarket team can set rider details.';
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_order_update_trg on public.orders;
create trigger pm_validate_order_update_trg
  before update on public.orders
  for each row execute function public.pm_validate_order_update();

-- ---------------------------------------------------------------------------
-- 9) Evidence URL check: the file must exist (j).
-- ---------------------------------------------------------------------------
create or replace function public.pm_evidence_url_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return NEW;
  end if;
  if NEW.url not like '%/storage/v1/object/public/evidence-media/' || auth.uid()::text || '/%' then
    raise exception 'Evidence must be a file you uploaded from this app.';
  end if;
  -- (M18) The file must actually exist in the caller's own folder —
  -- the URL pattern alone can be typed by hand. (Duration itself
  -- still cannot be verified by any trigger; that needs server-side
  -- media inspection.)
  if not exists (
    select 1 from storage.objects
    where bucket_id = 'evidence-media'
      and name = split_part(split_part(NEW.url, '/evidence-media/', 2), '?', 1)
  ) then
    raise exception 'Evidence must be a file you uploaded from this app.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_evidence_url_check_trg on public.evidence;
create trigger pm_evidence_url_check_trg
  before insert on public.evidence
  for each row execute function public.pm_evidence_url_check();

-- ---------------------------------------------------------------------------
-- 10) Message updates: blocked students cannot answer offers (l).
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
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_message_update_trg on public.messages;
create trigger pm_validate_message_update_trg
  before update on public.messages
  for each row execute function public.pm_validate_message_update();

-- ---------------------------------------------------------------------------
-- 11) Wallet balances, server-side (m). getBalances() fetched every
--     ledger row and summed client-side. This RPC returns the sums
--     per bucket; the caller must be the wallet owner or the team.
--     App wiring (switching getBalances to supabase.rpc) is a
--     follow-up — the RPC is harmless until then.
-- ---------------------------------------------------------------------------
create or replace function public.get_wallet_balances(p_user_id uuid)
returns table (bucket text, balance bigint)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Sign in first to read a wallet.';
  end if;
  if auth.uid() <> p_user_id and not public.pm_is_owner() then
    raise exception 'You can only read your own wallet.';
  end if;
  return query
    select w.bucket, coalesce(sum(w.amount), 0)
    from public.wallet_ledger w
    where w.user_id = p_user_id
    group by w.bucket;
end;
$$;

revoke execute on function public.get_wallet_balances(uuid) from public;
grant execute on function public.get_wallet_balances(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 12) One waybill, one order (g). A waybill number is proof for one
--     parcel on one order — the app now refuses reuse, and this
--     index stops a direct API call doing the same. Safe: a waybill
--     is only ever set on shipped orders, which can never be
--     cancelled, so no legit order is blocked.
-- ---------------------------------------------------------------------------
create unique index if not exists orders_waybill_number_unique_idx
  on public.orders (waybill_number) where waybill_number is not null;

-- Done. Milestone 18.
