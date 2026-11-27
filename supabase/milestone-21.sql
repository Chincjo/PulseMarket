-- ===========================================================================
-- Milestone 21 — Nightly deep-check fixes (2026-11-26 night run).
--
-- HOW TO RUN (code first, then SQL, only after Richard approves):
--   1. Push the app code first. Milestone 20's code must already be live.
--   2. REQUIRED APP CHANGE BEFORE RUNNING THIS FILE — DONE
--      2026-11-26 night run: in src/lib/shipping.js,
--      resolveReturn()'s recovery branch (the "already refunded"
--      close-out) now records the seller debt BEFORE flipping the
--      order to 'refunded' (Section 1 below refuses that flip
--      until the debt exists). The main paths in resolveReturn
--      and refundHeldOrder already recorded the debt first.
--   3. Run this whole file once in the Supabase SQL Editor, AFTER
--      milestone-20.sql has run. Do NOT run it before M20.
--   4. Pre-run checks (run as queries first; fix by hand if any
--      return rows): duplicate debt rows per order, duplicate open
--      disputes per order, duplicate invite codes, duplicate waybill
--      numbers. M20's unique indexes abort on duplicates.
--
-- WHAT IT FIXES (each section says which):
--   §1  M-1 CLOSED AT THE DATABASE: a seller-fault refund (buyer gets
--       the full total) or a team refund (buyer gets item + shipping)
--       can no longer be marked 'refunded' while a shipping advance
--       the seller already pocketed has no matching seller-debt row.
--       Without the debt, ₦1,750 was created on a ₦5,000 order
--       (₦1,325 under the old item+shipping amount). Buyer-fault
--       returns need no debt: the seller legitimately keeps the
--       shipping, advance included.
--   §2  The buyer-fault "remaining shipping" release leg can no
--       longer be written on a seller-fault return (it paid the
--       seller shipping a second time, on top of the buyer's refund).
--   §3  A seller who was rejected or flagged after listing can no
--       longer receive NEW orders (chats/offers/pickups with them
--       were already gated; orders were not). Blocked pairs cannot
--       order either. NOTE: the two-account test seller must be an
--       approved, unflagged student or new orders will be refused.
--   §4  Filing a dispute now freezes the order's money in the same
--       transaction (the freeze used to be a separate app call — a
--       crash between the two left an open dispute on unfrozen
--       money, which auto-release could then pay out).
--   §5  A seller can no longer forge a boost_purchases row with
--       status 'paid' (inserts must be 'pending_payment'; the team
--       confirms payment).
--   §6  An approved student can no longer swap or delete their ID
--       photos after approval (pending / rejected students still
--       can — that is the resubmit flow).
--   §7  A released or refunded order no longer freezes its listing's
--       photos/title/price/delivery details for ever — only a live
--       order freezes them.
--   §8  release_order() and §9 auto_release_overdue_orders() no
--       longer fail the whole money move when the listing was
--       flipped back to 'active' mid-order: they only flip a
--       listing that is still 'reserved'.
--   §10 (a) A shipping order must pass through 'shipped' (waybill +
--       PIN + tracking) before it can be marked delivered — held ->
--       delivered is now the meet-in-person path only.
--       (b) A resolved return cannot be opened again (re-opening
--       stalled every release while it sat open; something new goes
--       through a dispute).
--       (c) The team can correct a wrong delivery PIN, waybill
--       number or driver phone after shipping (a wrong PIN blocked
--       the buyer at handover and only the SQL Editor could fix
--       it). Photos stay locked.
--   §11 A ₦0 offer can no longer be accepted (it set agreed_price =
--       0, which the order insert refuses, stranding the price).
--       Declining it is still allowed.
--   §12 A verification row must point at ID photos that actually
--       exist in the verification-ids bucket (a fake path used to
--       pass) and must belong to the caller.
--   §13 Accepting an offer now declines the other pending offers
--       the other student sent in the same conversation (same fix
--       mirrored in src/lib/chat.js respondOfferLegacy, the path
--       that is live until M20 SQL runs) — two offers can no longer
--       both stand accepted.
--
-- IDEMPOTENT: every statement is CREATE OR REPLACE, DROP ... IF
-- EXISTS, or a policy drop + create. Safe to run twice.
-- NEVER re-run milestone-14 to milestone-18 after this file.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- §1) M-1 closed at the database: a refund that pays the buyer shipping
-- money cannot be marked 'refunded' while the seller still owes the
-- shipping advance back. Runs on the status flip, AFTER the app has
-- written the refund legs and the debt (refundHeldOrder and the main
-- resolveReturn path already write the debt first — see the file
-- header for the one recovery branch that must be fixed in the app
-- before this file runs).
-- ---------------------------------------------------------------------------
create or replace function public.pm_m21_require_refund_debt()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_advance integer := 0;
  v_debt integer := 0;
begin
  if NEW.status is distinct from 'refunded' then
    return NEW;
  end if;
  if OLD.status = 'refunded' then
    return NEW;
  end if;
  -- Only refunds that pay the buyer shipping money need the clawback:
  -- a seller-fault return (the buyer gets the full total) or a team
  -- refund with no return open (the buyer gets item + shipping). A
  -- buyer-fault return pays the buyer the item only and the seller
  -- keeps the shipping, advance included, so no debt is owed.
  -- OLD carries the reason the refund legs were priced from.
  if coalesce(OLD.return_reason, '') like 'Seller fault%'
     or coalesce(OLD.return_status, '') <> 'opened' then
    select coalesce(sum(amount), 0) into v_advance
    from public.wallet_ledger
    where order_id = OLD.id
      and kind = 'shipping_advance'
      and bucket = 'available';
    if v_advance > 0 then
      select coalesce(sum(amount), 0) into v_debt
      from public.wallet_ledger
      where order_id = OLD.id
        and kind = 'debt'
        and bucket = 'available';
      if v_debt <> -v_advance then
        raise exception 'A shipping advance of % was already paid to the seller — record it as a seller debt first, so the refund does not create money.', v_advance;
      end if;
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_m21_require_refund_debt_trg on public.orders;
create trigger pm_m21_require_refund_debt_trg
  before update on public.orders
  for each row execute function public.pm_m21_require_refund_debt();

-- ---------------------------------------------------------------------------
-- §2) The buyer-fault "remaining shipping" release leg is only for a
-- buyer-fault return. The ledger trigger never checked the fault, so
-- on a seller-fault return the seller (48h after delivery) could
-- also take shipping_fee - advance on top of the buyer's full refund.
-- The full release is unaffected: it requires no open return, while
-- this leg requires one, so the two can never be confused.
-- ---------------------------------------------------------------------------
create or replace function public.pm_m21_validate_remaining_shipping()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_advance integer := 0;
begin
  if NEW.kind <> 'release' or NEW.bucket <> 'available' then
    return NEW;
  end if;
  if NEW.order_id is null then
    return NEW;
  end if;
  select * into v_order from public.orders where id = NEW.order_id;
  if not found then
    return NEW;
  end if;
  if coalesce(v_order.return_status, '') = 'opened'
    and v_order.status in ('shipped', 'delivered') then
    select coalesce(sum(amount), 0) into v_advance
    from public.wallet_ledger
    where order_id = NEW.order_id
      and kind = 'shipping_advance'
      and bucket = 'available';
    if NEW.amount = greatest(v_order.shipping_fee - v_advance, 0)
      and coalesce(v_order.return_reason, '') not like 'Buyer fault%' then
      raise exception 'The remaining-shipping leg is only for a buyer-fault return.';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_m21_validate_remaining_shipping_trg on public.wallet_ledger;
create trigger pm_m21_validate_remaining_shipping_trg
  before insert on public.wallet_ledger
  for each row execute function public.pm_m21_validate_remaining_shipping();

-- ---------------------------------------------------------------------------
-- §3) A seller must still be an approved, unflagged student when an
-- order is placed — not only when they listed. A seller rejected or
-- flagged after listing stayed buyable, while chats, offers and
-- pickups with them were already gated. Blocked pairs cannot order.
-- Mirrors pm_validate_conversation_insert().
-- ---------------------------------------------------------------------------
create or replace function public.pm_m21_order_seller_verified()
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
    raise exception 'This seller is no longer a verified student — new orders are paused.';
  end if;
  if exists (
    select 1 from public.verifications
    where user_id = NEW.seller_id and coalesce(flagged, false)
  ) then
    raise exception 'This seller is under review — new orders are paused.';
  end if;
  if exists (
    select 1 from public.blocked_users
    where (blocker_id = NEW.buyer_id and blocked_id = NEW.seller_id)
       or (blocker_id = NEW.seller_id and blocked_id = NEW.buyer_id)
  ) then
    raise exception 'You cannot place an order with this student.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_m21_order_seller_verified_trg on public.orders;
create trigger pm_m21_order_seller_verified_trg
  before insert on public.orders
  for each row execute function public.pm_m21_order_seller_verified();

-- ---------------------------------------------------------------------------
-- §4) Filing a dispute freezes the order's money in the same
-- transaction as the dispute insert. Until now the freeze was a
-- separate app update: a crash between the two left an open dispute
-- on unfrozen money, which auto-release could then pay out. The
-- app's own freeze update afterwards is a harmless no-op, and the
-- Milestone 20 unfreeze-on-resolve backstop is untouched.
-- ---------------------------------------------------------------------------
create or replace function public.pm_m21_freeze_on_dispute_open()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.order_id is not null then
    update public.orders
    set frozen = true, updated_at = now()
    where id = NEW.order_id and coalesce(frozen, false) = false;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_m21_freeze_on_dispute_open_trg on public.disputes;
create trigger pm_m21_freeze_on_dispute_open_trg
  after insert on public.disputes
  for each row execute function public.pm_m21_freeze_on_dispute_open();

-- ---------------------------------------------------------------------------
-- §5) A seller can no longer forge a boost_purchases row with
-- status 'paid'. New rows must be 'pending_payment'; only the team
-- flips one to 'paid' after confirming payment (the purchase_boost
-- RPC inserts the row and bypasses RLS, so it is unaffected).
-- ---------------------------------------------------------------------------
drop policy if exists "Sellers insert their own boost purchases" on public.boost_purchases;
create policy "Sellers insert their own boost purchases"
  on public.boost_purchases for insert
  with check (seller_id = auth.uid() and status = 'pending_payment');

-- ---------------------------------------------------------------------------
-- §6) An approved student can no longer swap or delete their ID
-- photos after approval — the team reviewed those exact files.
-- Pending-review and rejected students can still replace them
-- (that is the resubmit flow), and students with no row yet can
-- still upload. Team access via the SQL Editor / service role is
-- unaffected (those bypass RLS).
-- ---------------------------------------------------------------------------
drop policy if exists "Students replace their own ID photos" on storage.objects;
create policy "Students replace their own ID photos"
  on storage.objects for update
  using (
    bucket_id = 'verification-ids'
    and (storage.foldername(name))[1] = auth.uid()::text
    and not exists (
      select 1 from public.verifications
      where user_id = auth.uid() and status = 'approved'
    )
  )
  with check (
    bucket_id = 'verification-ids'
    and (storage.foldername(name))[1] = auth.uid()::text
    and not exists (
      select 1 from public.verifications
      where user_id = auth.uid() and status = 'approved'
    )
  );

drop policy if exists "Students delete their own ID photos" on storage.objects;
create policy "Students delete their own ID photos"
  on storage.objects for delete
  using (
    bucket_id = 'verification-ids'
    and (storage.foldername(name))[1] = auth.uid()::text
    and not exists (
      select 1 from public.verifications
      where user_id = auth.uid() and status = 'approved'
    )
  );

-- ---------------------------------------------------------------------------
-- §7) pm_validate_listing_update(): milestone-20's live function with
-- ONLY the open-order freeze fixed (released / refunded orders no
-- longer freeze the listing for ever).
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
    -- (M21) 'Open' means a live order. A released or refunded order
    -- used to freeze the listing for ever; it no longer does.
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
          and o.status in ('reserved', 'paid', 'held', 'shipped', 'delivered')
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
  -- (Milestone 22) A non-seller may only move the status as part of
  -- an order flow, and the move must match their own order's state:
  -- 'reserved' while their order is reserved/paid (placing it),
  -- 'sold' once it is delivered/released (delivery / release), and
  -- 'active' once it is cancelled/refunded and no other order is
  -- still open. The old check only asked for SOME order linking the
  -- caller to the listing — any status, any age — so a buyer from a
  -- cancelled order months ago could flip a live listing to 'sold'
  -- or free a reserved one mid-order. The app enforces the same
  -- mapping in updateListing().
  if NEW.status = 'reserved' then
    if not exists (
      select 1 from public.orders o
      where o.listing_id = OLD.id and o.buyer_id = auth.uid()
        and o.status in ('reserved', 'paid')
    ) then
      raise exception 'Only the buyer of a reserved or paid order for this listing can mark it reserved.';
    end if;
  elsif NEW.status = 'sold' then
    if not exists (
      select 1 from public.orders o
      where o.listing_id = OLD.id and o.buyer_id = auth.uid()
        and o.status in ('delivered', 'released')
    ) then
      raise exception 'Only the buyer of a delivered or released order for this listing can mark it sold.';
    end if;
  elsif NEW.status = 'active' then
    if not exists (
      select 1 from public.orders o
      where o.listing_id = OLD.id and o.buyer_id = auth.uid()
        and o.status in ('cancelled', 'refunded')
    ) then
      raise exception 'Only the buyer of a cancelled or refunded order for this listing can put it back to active.';
    end if;
    if exists (
      select 1 from public.orders o
      where o.listing_id = OLD.id
        and o.status in ('reserved', 'paid', 'held', 'shipped', 'delivered')
    ) then
      raise exception 'This listing still has an open order — it cannot go back to active yet.';
    end if;
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
-- §8) release_order(): milestone-20's live function with ONLY the
-- listing flip guarded (flip to 'sold' only when still 'reserved').
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
  -- (M21) Only flip a listing that is still 'reserved'. The seller
  -- may have flipped it back to 'active' mid-order, and an active
  -- listing can only be reserved — so an unconditional flip failed
  -- the whole release and stranded the money. The money move must
  -- never fail over a listing label.
  update public.listings
  set status = 'sold'
  where id = v_order.listing_id
    and status = 'reserved';

  return v_order;
end;
$$;

revoke execute on function public.release_order(uuid) from public;
grant execute on function public.release_order(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- §9) auto_release_overdue_orders(): milestone-20's live function with
-- ONLY the listing flip guarded (flip to 'sold' only when still
-- 'reserved').
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

    -- (M21) Only flip a listing that is still 'reserved' — see
    -- release_order() above. An unconditional flip failed the
    -- per-order block and the order was silently skipped every run.
    update public.listings
    set status = 'sold'
    where id = o.listing_id
      and status = 'reserved';

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
-- §10) pm_validate_order_update(): milestone-20's live function with
-- ONLY three fixes: (a) held -> delivered is meetup-only, (b) a
-- resolved return cannot be opened again, (c) the team may
-- correct shipping-proof text fields after shipping.
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
    elsif OLD.status = 'held' and NEW.status = 'delivered' and v_is_buyer and OLD.payment_method = 'held' and OLD.delivery_method = 'meetup' then
      -- (M21) held -> delivered is the meet-in-person path only. A
      -- shipping order must pass through 'shipped' (waybill + PIN +
      -- tracking) before it can be delivered.
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
      -- (M21) Team correction: a wrong delivery PIN blocks the buyer
      -- at handover and a typo'd waybill number breaks tracking, so
      -- the team may fix the text fields after shipping. Team-only,
      -- no status change, and the photos stay locked (a re-uploaded
      -- photo cannot be re-pointed here).
      -- (Milestone 22) The flag stays locked here too: the old
      -- condition let the team flip shipping_advance_released in
      -- the same update as a PIN fix, even with no advance in the
      -- ledger — which then made the advance retry skip a
      -- legitimate advance. (A flag-only change still goes through
      -- the seller path above, which requires the advance.)
      if v_owner and NEW.status = OLD.status and OLD.status in ('shipped', 'delivered')
        and NEW.waybill_photo is not distinct from OLD.waybill_photo
        and NEW.receipt_photo is not distinct from OLD.receipt_photo
        and NEW.shipping_proof_at is not distinct from OLD.shipping_proof_at
        and NEW.shipping_advance_released is not distinct from OLD.shipping_advance_released then
        null;
      elsif not (v_is_seller and OLD.status = 'held' and NEW.status = 'shipped') then
        raise exception 'Shipping proof can only be submitted by the seller when the money is held.';
      end if;
      if NEW.delivery_pin is not null and NEW.delivery_pin !~ '^[0-9]{6}$' then
        raise exception 'The delivery PIN must be 6 digits.';
      end if;
      if NEW.waybill_number is not null and btrim(NEW.waybill_number) = '' then
        raise exception 'The waybill number cannot be empty.';
      end if;
      -- (M21) Only a photo that actually changed is re-checked, and
      -- it is checked against the seller's folder, not the caller's:
      -- the team correcting a PIN must not trip on the seller's
      -- existing photo.
      if NEW.waybill_photo is distinct from OLD.waybill_photo
        and NEW.waybill_photo is not null
        and NEW.waybill_photo not like '%/storage/v1/object/public/evidence-media/' || OLD.seller_id::text || '/%' then
        raise exception 'The waybill photo must be a photo uploaded from this app.';
      end if;
      if NEW.receipt_photo is distinct from OLD.receipt_photo
        and NEW.receipt_photo is not null
        and NEW.receipt_photo not like '%/storage/v1/object/public/evidence-media/' || OLD.seller_id::text || '/%' then
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
      -- (M21) A return that was already resolved cannot be opened
      -- again — re-opening stalled every release while it sat open.
      -- Something new after a resolution goes through a dispute.
      if OLD.return_status = 'resolved' then
        raise exception 'This return was already resolved — it cannot be opened again. If something new came up, file a dispute and the PulseMarket team will look at it.';
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
-- §11) respond_offer(): milestone-20's live function with ONLY the
-- ₦0-accept refusal added.
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
  -- (M21) A ₦0 offer must never be accepted: it would set
  -- agreed_price = 0, which the order insert then refuses, leaving
  -- a stuck agreed price. Declining it is still allowed.
  if p_status = 'accepted' and v_msg.offer_amount <= 0 then
    raise exception 'An offer must be more than ₦0 to accept.';
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

-- ---------------------------------------------------------------------------
-- §12) pm_validate_verification_insert(): milestone-19's live function
-- with ONLY the object-exists and caller checks added.
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
  -- (M21) A verification row belongs to the caller. (RLS already
  -- enforces this; the trigger is the backstop for a direct call.)
  if NEW.user_id is distinct from auth.uid() then
    raise exception 'You can only verify your own student account.';
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
  -- (M21) The path pattern alone proves nothing — the file must
  -- actually exist in the private bucket (the same check resubmit
  -- already does). Without this, a row can point at photos that
  -- were never uploaded and the team can approve a student whose
  -- ID was never seen.
  if not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(NEW.id_front_url, '?', 1)
    )
    or not exists (
      select 1 from storage.objects
      where bucket_id = 'verification-ids'
        and name = split_part(NEW.id_back_url, '?', 1)
    ) then
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

-- ---------------------------------------------------------------------------
-- §13) Accepting an offer answers the other pending offers in the
-- same conversation (other student's offers only). Without this,
-- two offers could both end up 'accepted' and the agreed price
-- would follow whichever was accepted last — the state is
-- ambiguous even though the money always follows an amount the
-- buyer offered. Only the other student's pending offers are
-- declined here: pm_validate_message_update refuses answering
-- your own offer, so an offer this caller sent stays pending
-- (the other student can still answer it, and accepting it then
-- moves the agreed price). Each declined row passes the trigger
-- for the same reasons the accepted one does — pending to
-- declined, caller is the responder and a participant, chat
-- unblocked, both students verified (checked above).
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
  -- (M21) A ₦0 offer must never be accepted: it would set
  -- agreed_price = 0, which the order insert then refuses, leaving
  -- a stuck agreed price. Declining it is still allowed.
  if p_status = 'accepted' and v_msg.offer_amount <= 0 then
    raise exception 'An offer must be more than ₦0 to accept.';
  end if;

  -- (Milestone 22) Lock the conversation row too: two opposite
  -- accepts (buyer accepts the seller's offer while the seller
  -- accepts the buyer's) lock different message rows, so both could
  -- land without this. Answers in one conversation now queue here,
  -- so only one accept can stand.
  select buyer_id, seller_id into v_buyer, v_seller
  from public.conversations
  where id = v_msg.conversation_id
  for update;

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
    -- (M22) Answer ALL other pending offers in this conversation,
    -- including ones this caller sent, so only one offer can stand
    -- accepted at a time. (M21 declined only the other student's:
    -- your own pending offers stayed open and the other student
    -- could still accept one, leaving two 'accepted' offers. The
    -- message-update trigger now lets a sender decline — withdraw —
    -- their own offer, so this no longer rolls the accept back.)
    update public.messages
    set offer_status = 'declined'
    where conversation_id = v_msg.conversation_id
      and kind = 'offer'
      and coalesce(offer_status, '') = 'pending'
      and id <> v_msg.id;
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

-- Done. Milestone 21.
