-- PulseMarket Milestone 15 — SECOND AUDIT FIXES (money core).
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: every statement
-- below is idempotent (CREATE OR REPLACE, or CREATE UNIQUE INDEX IF
-- NOT EXISTS), so re-running it changes nothing.
--
-- RUN ORDER — READ THIS FIRST: deploy the app code that goes with
-- this file FIRST, then run this file. Two of the new rules need the
-- new app code:
--   * The shipping-advance rule now requires the waybill + receipt
--     proof to already be on the order. The OLD app inserts the
--     advance BEFORE it saves the proof, so running this file first
--     would refuse every advance until the new app ships.
--   * The order-insert rule now prices shipping from the ship-to
--     state. The OLD app priced it from the buyer's university state,
--     so an order whose ship-to state differs would be refused.
-- The new app tolerates the old database in between (an advance that
-- cannot be released yet is reported as pending and can be retried
-- from the tracking page), but the old app does NOT tolerate this
-- file. App first, SQL second.
--
-- WHAT THE SECOND AUDIT FOUND (all verified by reading the code and
-- the Milestone 14 SQL — no live run was used):
--
--   1. HANDOFF GUESS RACE. verify_seller_code read the attempt count,
--      added 1 in memory and wrote it back. Two wrong guesses sent at
--      the same time both read the same count and both wrote the same
--      number, so parallel guessing could stay under the 5-guess lock
--      forever. The function now locks the order row (FOR UPDATE) and
--      increments the count atomically in the database.
--   2. BACKDATED delivered_at. confirmDelivery / releaseOrder set the
--      timestamps from the phone's clock, and the trigger only checked
--      that the status moved. A buyer could confirm delivery with
--      delivered_at set 3 days in the past and the seller could then
--      release immediately, skipping the 48-hour return window. The
--      trigger now stamps paid_at / held_at / delivered_at /
--      released_at itself (now()) on the matching status move, and a
--      timestamp may only change together with that move.
--   3. REFUND MINTING. A buyer could insert a 'refund' available row
--      for themselves (up to item price + shipping) with no return
--      open and no money ever leaving hold — free money, and the real
--      refund then failed on the unique index. A refund to the buyer
--      now needs an open return, the exact fault amount, and its held
--      leg already written. A release available row likewise needs its
--      held leg (or, for the buyer-fault leg, the refund held leg).
--   4. REPAYMENT MINTING. A seller could insert 'repayment' rows for
--      themselves for any amount — the app never writes repayments,
--      so this was pure attack surface. A repayment may now never
--      exceed the seller's outstanding debt for that order.
--   5. DEBT FRAMING. A buyer could insert 'debt' rows against the
--      seller of their order (any amount), tanking the seller's
--      balance and blocking their listing/withdrawal. Only the
--      PulseMarket team may now record a debt.
--   6. FAKE HOLD. A buyer could insert the 'hold' row themselves
--      before the team ever confirmed a bank transfer — blocking the
--      real hold on the unique index and leaving the order stuck. Only
--      the team may now write a hold.
--   7. DOUBLE-SPEND ACROSS KINDS. The unique indexes stop two
--      releases, but a release AND a refund could both drain the same
--      hold (different kinds, different indexes), including the race
--      where release and return-resolution run at the same time. Held
--      money can now never leave hold more than it entered: every
--      negative held move must keep the order's held sum >= 0.
--   8. STATUS-ONLY MONEY LIES. An order could be marked 'released'
--      with no ledger rows at all (seller never paid), 'refunded'
--      with no refund, or 'held' with no hold. Each of those status
--      moves now requires the matching ledger rows to already exist.
--   9. RELEASE WHILE A RETURN IS OPEN. Nothing server-side stopped
--      a release after the buyer opened a return — the return (and
--      the refund) then had nothing left to resolve. Release is now
--      refused while return_status is 'opened'. (The app refuses it
--      too, and hides the button.)
--  10. SHIPPING ADVANCE WITHOUT PROOF. The Milestone 14 comment
--      admitted it: the advance was written before the proof fields,
--      so the server could not check them, and a seller could take
--      half the shipping fee with no waybill or receipt. The app now
--      saves the proof (and ships the order) first; the advance
--      requires status shipped/delivered AND a waybill number AND a
--      receipt photo on the order AND an eligible courier.
--  11. SHIPPED WITH NO PROOF AT ALL. held -> shipped needed no
--      waybill, photo or PIN — a seller could mark an order shipped
--      with nothing behind it. The move now requires a waybill
--      number, a waybill photo and a delivery PIN.
--  12. SHIPPING FEE PRICED FROM THE WRONG STATE. createOrder priced
--      the zone from the buyer's university state, not the ship-to
--      state — so the total shown at checkout and the total charged
--      could differ, and a buyer shipping to a far state could be
--      charged the same-state fee. The server now re-derives the fee
--      from ship_to_state vs the listing's state (same neighbour map
--      as src/lib/payments.js), and a shipping order must name a
--      real courier (meet-in-person orders must name none).
--  13. DOUBLE SALE RACE. Two buyers could reserve the same listing
--      at the same time — both read it 'active' before either held
--      it. The insert now locks the listing row, and a partial unique
--      index allows only one open order per listing.
--  14. HANDOFF PHOTO SWAPPED AFTER CONFIRMING. Either side could
--      replace their handover photo after confirming, rewriting the
--      evidence. A photo is now frozen once that side has confirmed.
--
-- What this file does NOT change: the handoff-code table and the
-- verify flow (only the race is fixed), the fee rules, the 48-hour
-- rule itself, the return fault amounts, manual escrow (no Paystack),
-- and the auth.uid() = null escape hatch for pg_cron / SQL Editor
-- work (the server-side auto-release still bypasses these triggers
-- exactly as Milestone 14 intended).
--
-- Run AFTER milestones 3–14, and AFTER deploying the app code that
-- goes with it (see RUN ORDER above).

-- ---------------------------------------------------------------------------
-- 1) Shipping-zone fee, mirroring src/lib/payments.js shippingZone().
--    Same state (or unknown state) 1500, neighbouring state 2500,
--    far state 3500. Neighbour lists copied exactly from payments.js.
-- ---------------------------------------------------------------------------
create or replace function public.pm_shipping_fee(p_seller_state text, p_ship_to_state text)
returns integer
language sql
immutable
as $$
  select case
    when p_seller_state is null or p_ship_to_state is null
      or p_seller_state = p_ship_to_state then 1500
    when (p_seller_state = 'Rivers' and p_ship_to_state in ('Delta', 'Imo'))
      or (p_seller_state = 'Lagos' and p_ship_to_state in ('Ogun'))
      or (p_seller_state = 'Oyo' and p_ship_to_state in ('Osun', 'Ogun', 'Kwara', 'Ondo'))
      or (p_seller_state = 'Osun' and p_ship_to_state in ('Oyo', 'Ondo', 'Kwara', 'Edo'))
      or (p_seller_state = 'Enugu' and p_ship_to_state in ('Anambra'))
      or (p_seller_state = 'Kaduna' and p_ship_to_state in ('Niger', 'Plateau', 'Kano'))
      or (p_seller_state = 'Edo' and p_ship_to_state in ('Delta', 'Ondo'))
      or (p_seller_state = 'Kwara' and p_ship_to_state in ('Oyo', 'Osun', 'Niger'))
      or (p_seller_state = 'Ondo' and p_ship_to_state in ('Oyo', 'Osun', 'Edo', 'Delta', 'Ogun'))
      or (p_seller_state = 'Imo' and p_ship_to_state in ('Rivers', 'Anambra'))
      or (p_seller_state = 'Niger' and p_ship_to_state in ('Kaduna', 'Kwara', 'Plateau'))
      or (p_seller_state = 'Anambra' and p_ship_to_state in ('Enugu', 'Imo', 'Delta'))
      or (p_seller_state = 'Plateau' and p_ship_to_state in ('Kaduna', 'Niger'))
      or (p_seller_state = 'Kano' and p_ship_to_state in ('Kaduna'))
      or (p_seller_state = 'Delta' and p_ship_to_state in ('Edo', 'Rivers', 'Anambra', 'Ondo'))
      or (p_seller_state = 'Ogun' and p_ship_to_state in ('Lagos', 'Oyo', 'Ondo'))
    then 2500
    else 3500
  end;
$$;

-- ---------------------------------------------------------------------------
-- 2) verify_seller_code — same behaviour as Milestone 14, but the
--    order row is locked (FOR UPDATE) and a wrong guess increments
--    the count atomically in the database. Parallel wrong guesses
--    now queue behind the lock and each one counts, so the 5-guess
--    lock can no longer be raced past. Scanning a closed order is
--    also refused now.
-- ---------------------------------------------------------------------------
create or replace function public.verify_seller_code(p_order_id uuid, p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
  v_code text;
  v_attempts integer;
  v_typed text;
begin
  if auth.uid() is null then
    raise exception 'Sign in first to scan the seller code.';
  end if;
  v_typed := upper(btrim(coalesce(p_code, '')));
  if v_typed = '' then
    raise exception 'Type the seller code shown on the seller''s phone.';
  end if;

  -- Lock the order row first: concurrent scans for this order queue
  -- here, so each one sees the fresh attempt count (Milestone 14
  -- read the count without a lock, and parallel wrong guesses all
  -- wrote back the same number).
  select * into v_order from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'Order not found.';
  end if;
  if v_order.delivery_method <> 'meetup' then
    raise exception 'This handoff is only for meet-in-person orders.';
  end if;
  if v_order.status in ('cancelled', 'refunded', 'released') then
    raise exception 'This order is closed — there is no handoff to scan.';
  end if;
  if v_order.buyer_id <> auth.uid() then
    raise exception 'Only the buyer can scan the seller code.';
  end if;
  if v_order.handoff_locked then
    raise exception 'This handoff is locked — contact support.';
  end if;
  if v_order.handoff_scanned_at is not null then
    raise exception 'This handoff has already been scanned.';
  end if;

  select code into v_code from public.handoff_codes where order_id = p_order_id;
  if v_code is null then
    raise exception 'This handoff has no seller code yet — the seller opens the handoff first.';
  end if;

  -- From here on the orders trigger would refuse these writes from
  -- an app user, so the flag below tells it this change came from
  -- the code check itself. The flag is transaction-local
  -- (set_config ... true) and cannot be set through the API.
  perform set_config('pulsemarket.handoff_rpc', 'true', true);

  if v_typed = v_code then
    update public.orders
    set handoff_scanned_at = now(), updated_at = now()
    where id = p_order_id;
    return true;
  end if;

  -- Wrong code: count it atomically, log it, lock at 5 and flag the
  -- account — then return false (never raise here: an exception
  -- would undo the counting).
  update public.orders
  set code_attempts = code_attempts + 1, updated_at = now()
  where id = p_order_id
  returning code_attempts into v_attempts;

  if v_attempts >= 5 then
    update public.orders
    set handoff_locked = true, updated_at = now()
    where id = p_order_id;
    update public.verifications set flagged = true where user_id = auth.uid();
    insert into public.security_log (user_id, order_id, action, detail)
    values (auth.uid(), p_order_id, 'wrong_code',
            'Wrong seller code attempt ' || v_attempts || ' of 5 for order ' || v_order.code || '.');
    insert into public.security_log (user_id, order_id, action, detail)
    values (auth.uid(), p_order_id, 'handoff_locked',
            'Handoff locked after ' || v_attempts || ' wrong seller codes for order ' || v_order.code || '.');
  else
    insert into public.security_log (user_id, order_id, action, detail)
    values (auth.uid(), p_order_id, 'wrong_code',
            'Wrong seller code attempt ' || v_attempts || ' of 5 for order ' || v_order.code || '.');
  end if;
  return false;
end;
$$;

revoke execute on function public.verify_seller_code(uuid, text) from public;
grant execute on function public.verify_seller_code(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) Orders — insert validation. Same as Milestone 14, plus:
--    the listing row is locked while it is checked (double-sale
--    race), the shipping fee must match the zone for ship_to_state
--    vs the listing's state, and a shipping order must name a real
--    courier while a meet-in-person order names none.
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
  -- (The partial unique index in section 5 is the backstop — it
  -- refuses a second open order for the listing even if the lock
  -- were ever bypassed.)
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
  if NEW.item_price <> v_listing.price then
    raise exception 'The order price must match the listing price.';
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
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_order_insert_trg on public.orders;
create trigger pm_validate_order_insert_trg
  before insert on public.orders
  for each row execute function public.pm_validate_order_insert();

-- ---------------------------------------------------------------------------
-- 4) Orders — update validation. Same as Milestone 14, plus:
--    (a) the four money timestamps are stamped by the database
--        (now()) on the status move they belong to, and may only
--        change together with that move — a backdated delivered_at
--        can no longer skip the 48-hour return window;
--    (b) paid -> held needs the hold row, released needs both
--        release legs, refunded needs both refund legs — an order
--        can no longer be marked paid/held/released/refunded with
--        no money behind it;
--    (c) release is refused while a return is open;
--    (d) held -> shipped needs a waybill number, a waybill photo
--        and a delivery PIN;
--    (e) a handover photo cannot be swapped after that side
--        confirmed;
--    (f) the shipping-advance flag may be set on its own only by
--        the seller, on a shipped/delivered order whose proof is
--        complete and whose advance is already in the ledger (the
--        retry step in submitShippingProof).
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

  -- 4) Status moves: only the listed actor may make each move.
  if NEW.status is distinct from OLD.status then
    -- (c) A return that is open stops any release: the money must
    -- stay put until the team resolves the return.
    if NEW.status = 'released' and coalesce(OLD.return_status, '') = 'opened' then
      raise exception 'A return is open for this order — the PulseMarket team resolves it first.';
    end if;

    if OLD.status = 'reserved' and NEW.status = 'paid' and v_is_buyer and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'reserved' and NEW.status = 'delivered' and v_is_buyer and OLD.payment_method = 'cash' then
      null;
    elsif OLD.status = 'reserved' and NEW.status = 'cancelled' and v_is_buyer then
      null;
    elsif OLD.status = 'paid' and NEW.status = 'held' and v_owner and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'paid' and NEW.status = 'cancelled' and v_is_buyer then
      null;
    elsif OLD.status = 'held' and NEW.status = 'shipped' and v_is_seller and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'held' and NEW.status = 'delivered' and v_is_buyer and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'held' and NEW.status = 'released' and (v_is_buyer or v_owner) and OLD.payment_method = 'held' then
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
-- 5) One open order per listing. Two buyers reserving the same item
--    at the same time now fail here even if both read the listing as
--    active: the second insert hits this index. Cancelled, refunded
--    and released orders do not count, so a cancelled order never
--    blocks a later buyer.
-- ---------------------------------------------------------------------------
create unique index if not exists orders_one_open_order_per_listing_idx
  on public.orders (listing_id)
  where status in ('reserved', 'paid', 'held', 'shipped', 'delivered');

-- ---------------------------------------------------------------------------
-- 6) Wallet ledger — same as Milestone 14, plus:
--    * a hold may only be written by the team (a buyer used to be
--      able to insert one and block the real hold);
--    * a debt may only be recorded by the team (a buyer used to be
--      able to frame the seller with fake debts);
--    * a repayment may never exceed the outstanding debt for that
--      order (a seller used to mint money with repayment rows);
--    * a refund out of hold needs an open return (or a
--      reserved/paid order being cancelled); a refund to the buyer
--      needs an open return, the exact fault amount, and its held
--      leg already written;
--    * a release needs the money held, the right status, no open
--      return (full leg) and its held leg already written (the
--      buyer-fault leg needs the refund held leg instead);
--    * a shipping advance needs status shipped/delivered AND a
--      waybill number AND a receipt photo on the order (the proof
--      the app saves before it writes the advance), and its held
--      leg already written for the available leg;
--    * held money can never leave hold more than entered: every
--      negative held move must keep the order's held sum >= 0, so
--      a release and a refund (or two racing money moves) can no
--      longer drain the same hold twice;
--    * a withdrawal may never take the available balance below 0;
--    * no money move may happen on a frozen order.
--    The app writes ledger rows in pairs (held leg first, then the
--    available leg) in one insert, so the "held leg already written"
--    checks pass for every real flow — including the server-side
--    auto-release, which bypasses this trigger (no signed-in user)
--    exactly as Milestone 14 intended.
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
    select * into v_order from public.orders where id = NEW.order_id;
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
    if NEW.user_id <> v_order.seller_id or NEW.bucket <> 'held'
      or NEW.amount <> v_order.total then
      raise exception 'A hold must put the order total in the seller''s held bucket.';
    end if;
  elsif NEW.kind = 'release' then
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
      if v_order.status not in ('held', 'delivered') then
        raise exception 'A release can only be written while the order is held or delivered.';
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
        if v_order.status not in ('held', 'delivered') then
          raise exception 'A release can only be written while the order is held or delivered.';
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
    if v_order.payment_method <> 'held' or v_order.status not in ('shipped', 'delivered') then
      raise exception 'A shipping advance is only paid once the order has shipped.';
    end if;
    if v_order.courier not in ('GIG Logistics', 'GUO Transport', 'DHL Domestic', 'Peace Logistics', 'ABC Transport') then
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
    if NEW.bucket = 'held' then
      if NEW.user_id <> v_order.seller_id
        or NEW.amount <> -(v_order.total - v_advance) then
        raise exception 'A refund must take exactly what is still held (total minus any advance already paid).';
      end if;
      -- Either a return is open (the normal refund), or the order
      -- is still reserved/paid and the hold is being reversed on
      -- cancellation.
      if coalesce(v_order.return_status, '') <> 'opened'
        and v_order.status not in ('reserved', 'paid') then
        raise exception 'A refund out of hold needs an open return.';
      end if;
    elsif NEW.bucket = 'available' then
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
        if NEW.amount <> v_order.item_price + v_order.shipping_fee then
          raise exception 'A seller-fault refund pays the buyer the item price plus the shipping fee.';
        end if;
      elsif v_order.return_reason like 'Buyer fault%' then
        if NEW.amount <> v_order.item_price then
          raise exception 'A buyer-fault refund pays the buyer the item price only.';
        end if;
      else
        raise exception 'A refund to the buyer needs a return reason that says whose fault it is.';
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
    if NEW.order_id is null then
      raise exception 'A repayment needs an order.';
    end if;
    if NEW.user_id <> v_order.seller_id then
      raise exception 'A repayment belongs to the seller who owed the debt.';
    end if;
    if NEW.bucket <> 'available' or NEW.amount <= 0 then
      raise exception 'A repayment is a positive available entry.';
    end if;
    -- A repayment may never exceed what the seller still owes on
    -- this order — otherwise a seller could mint money by writing
    -- repayment rows for themselves.
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
  -- two rows of the SAME kind.
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
-- Done. Verify in the SQL Editor with a two-account test: checkout ->
-- pay -> hold -> ship (proof first, advance second) -> deliver ->
-- release, plus a return (release refused while it is open) and a
-- wrong-code lock (5 parallel wrong guesses still lock at 5).
-- If the team ever needs a manual correction that a trigger refuses,
-- do it from the SQL Editor (no signed-in user there, so the triggers
-- step aside) — never by weakening these rules.
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- SECOND AUDIT — COORDINATOR ADDITIONS (appended after the money-core fixes).
-- Same rules as the rest of this file: idempotent, app code FIRST, then
-- run this file. Everything below was found by the two other second-audit
-- teams and consolidated here so there is ONE new migration to run.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- A) Listing updates: the seller could set a free permanent boost and
--    change university/state/photos directly (Milestone 14 returned NEW
--    unconditionally for the seller). Views could never move at all —
--    bumpViews() was refused for non-sellers, so view counts sat at 0.
--    Now: a view count may only ever go up by exactly one (anyone);
--    the seller may edit the listing itself but not its identity,
--    university, state or view count; a boost lasts at most 72 hours
--    from now (the longest real tier) and the tier must be a real one.
--    Order participants may still only change the status, as before.
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
    if NEW.boost_tier is not null and NEW.boost_tier not in (500, 1000) then
      raise exception 'Unknown boost tier.';
    end if;
    if NEW.boosted_until is not null
      and (NEW.boosted_until < now() or NEW.boosted_until > now() + interval '72 hours')
    then
      raise exception 'A boost can last at most 72 hours from now.';
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
  return NEW;
end;
$$;

drop trigger if exists pm_validate_listing_update_trg on public.listings;
create trigger pm_validate_listing_update_trg
  before update on public.listings
  for each row execute function public.pm_validate_listing_update();

-- ---------------------------------------------------------------------------
-- B) Verification identity lock: Milestone 14 blocked status/flagged
--    changes, but a student could still change university, student_id
--    and invite_code after submitting, and could set referred_by to
--    their own invite code (self-referral). Now university, student ID
--    and invite code are immutable after insert; a referral can only
--    be filled in once (from empty) and never to your own code.
--    The team (owner) bypass is unchanged.
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
  return NEW;
end;
$$;

drop trigger if exists pm_validate_verification_insert_trg on public.verifications;
create trigger pm_validate_verification_insert_trg
  before insert on public.verifications
  for each row execute function public.pm_validate_verification_insert();

create or replace function public.pm_validate_verification_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
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
    or NEW.invite_code is distinct from OLD.invite_code
  then
    raise exception 'University, student ID and invite code cannot be changed after verification is submitted.';
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
-- C) Chat integrity in the database. The app now refuses these, but a
--    direct API call could still do them — so the database refuses too:
--    (1) messages/pickup tickets between blocked students;
--    (2) pickup tickets with an invented spot, a past date, or a date
--        more than 90 days out, or a malformed time;
--    (3) new conversations involving a flagged account;
--    (4) offers above ₦10,000,000 (CHECK, NOT VALID so any legacy row
--        cannot fail the migration).
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_message_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_other uuid;
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
  return NEW;
end;
$$;

drop trigger if exists pm_validate_message_insert_trg on public.messages;
create trigger pm_validate_message_insert_trg
  before insert on public.messages
  for each row execute function public.pm_validate_message_insert();

create or replace function public.pm_validate_pickup_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_other uuid;
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

create or replace function public.pm_validate_conversation_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return NEW;
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

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'messages_offer_amount_max'
  ) then
    alter table public.messages
      add constraint messages_offer_amount_max
      check (offer_amount is null or offer_amount <= 10000000) not valid;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- D) Notification rate limit. insert_notification() checked WHO you may
--    notify but not HOW OFTEN — a direct RPC loop could flood one
--    student's inbox without limit. The sender is now recorded on the
--    row, and one caller may send at most 120 notifications per hour
--    (plenty for real chats and order events; an RPC loop is useless
--    at that rate). Direct table inserts stay self-only, so the RPC
--    is the only cross-user path and the cap covers it.
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
-- E) Evidence files could be swapped after verification. The
--    evidence-media bucket's file-replace policy (if one exists — the
--    bucket itself was created outside these SQL files, so its policy
--    names are not known here) would let a student replace a verified
--    video's file while the row keeps its tick. Drop any UPDATE policy
--    on storage.objects that mentions the evidence-media bucket. The
--    app never updates a stored file (uploads are inserts, deletes
--    are deletes), so nothing legit breaks. If no such policy exists
--    this block is a no-op.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select policyname from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and cmd = 'UPDATE'
      and (qual like '%evidence-media%' or with_check like '%evidence-media%')
  loop
    execute format('drop policy if exists %I on storage.objects', r.policyname);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- F) One-time data fix: listings created before the Sell form used the
--    canonical courier names still store the short names ("GIG", "GUO",
--    "Peace Mass Transit", "DHL", "Bus Park"), which the shipping
--    advance logic and the ledger trigger do not recognise — those
--    listings could never earn their 50% shipping advance. Map them
--    to the canonical names. Idempotent: after the first run no rows
--    match the old names.
-- ---------------------------------------------------------------------------
update public.listings set courier = 'GIG Logistics' where courier = 'GIG';
update public.listings set courier = 'GUO Transport' where courier = 'GUO';
update public.listings set courier = 'Peace Logistics' where courier = 'Peace Mass Transit';
update public.listings set courier = 'DHL Domestic' where courier = 'DHL';
update public.listings set courier = 'Bus Park Waybill' where courier = 'Bus Park';
