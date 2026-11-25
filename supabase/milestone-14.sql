-- PulseMarket Milestone 14 — SECURITY FIXES (server-side enforcement).
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: every statement
-- below is idempotent (CREATE OR REPLACE, DROP IF EXISTS, CREATE
-- UNIQUE INDEX IF NOT EXISTS, or a DO block that ignores
-- "already exists"), so re-running it changes nothing.
--
-- RUN ORDER — READ THIS FIRST: deploy the app code that goes with
-- this file FIRST (the push that includes the new handoff.js), THEN
-- run this file. The handoff-code move below nulls orders.seller_code
-- after copying the codes into handoff_codes; the old app code reads
-- the code from orders.seller_code, the new code reads handoff_codes.
-- Running this file before deploying the new code would break the
-- handoff scan until the code ships. Nothing else in this file
-- depends on deploy order.
--
-- WHY THIS FILE EXISTS: until now almost every money and handoff
-- rule lived ONLY in the app (src/lib/*.js). Anybody can call the
-- Supabase API directly with the public anon key and skip the app
-- entirely, so app-only checks are not security. This file moves the
-- rules into the database, where a direct API call cannot dodge them:
--
--   1. SELLER CODE WAS READABLE BY THE BUYER. The one-time handoff
--      code (PM-XXXXXX) sat in orders.seller_code, and the buyer can
--      read the whole order row — so a buyer could look the code up
--      without ever meeting the seller, and "scan" it from home. The
--      code now lives in a new seller-only table (handoff_codes) and
--      is checked by a server function (verify_seller_code) that
--      never returns the code. Old codes are copied over, then
--      orders.seller_code is emptied and the database refuses to
--      ever put a code there again.
--   2. ANY ORDER PARTICIPANT COULD REWRITE ANY ORDER. The orders
--      UPDATE policy let buyer, seller or owner change ANY field —
--      status straight to 'released', money amounts, frozen=false,
--      buyer_confirmed=true, delivery PIN, anything. A trigger now
--      enforces the legal status moves (with the right actor for
--      each), freezes money fields forever, and re-checks the
--      handoff / unboxing-video gates on delivery and release.
--      New orders are validated too: price must match the listing,
--      fees must match the fee rules, shipping must be a set zone
--      fee, and a new order always starts 'reserved'.
--   3. THE LEDGER COULD BE FORGED. Any order participant could
--      insert wallet_ledger rows with any amount — including paying
--      themselves a fortune. A trigger now checks every ledger row
--      against the order (hold = total, release = price + shipping
--      minus any advance, advance = half the shipping fee, and so
--      on), and one-per-order unique indexes make a double hold,
--      double release, double advance or double refund impossible
--      even if two devices race.
--   4. A STUDENT COULD VERIFY THEMSELVES. The verifications UPDATE
--      policy let a student change their own status to 'verified'
--      and flag/unflag themselves. Only the team can change status
--      or flagged now (the handoff-lock flagging still works — it
--      runs inside verify_seller_code).
--   5. EVIDENCE COULD BE FAKED. An evidence row could be inserted
--      with verified=true and any duration, which would pass the
--      delivery gate. The database now recomputes verified from the
--      kind / media / duration rules on every insert and ignores
--      whatever the caller claimed.
--   6. OFFERS COULD BE SELF-ACCEPTED AND MESSAGES REWRITTEN. Any
--      participant could update any message (including accepting
--      their own offer, which set the agreed price) and set
--      conversations.agreed_price to anything. Only the OTHER
--      participant may accept/decline a pending offer now, messages
--      cannot be edited, and an agreed price must match an offer
--      the other side actually accepted.
--   7. NOTIFICATION SPAM. insert_notification() let any participant
--      of an order/conversation notify ANY user (not just the other
--      party). The recipient must now be the other participant, the
--      caller themselves, or the team.
--   8. LISTING STATUS COULD BE FLIPPED BY A BUYER, and a listing
--      could be posted with no verification row. Order participants
--      may now change a listing's status only (reserved/sold/active)
--      so checkout/release/cancel work, nothing else; posting a
--      listing requires a verification row.
--   9. SMALL HARDENING: security_log rows can no longer be filed
--      under somebody else's user id; a reporter can delete only
--      their own OPEN dispute (this also makes fileDispute's own
--      freeze-failure cleanup work — it was silently refused
--      before); blocked_users cannot block themselves; message
--      bodies are capped at 1000 chars and rating comments at 280.
--
-- ESCAPE HATCH: the triggers skip when there is no signed-in user
-- (auth.uid() is null) — that is the server side: pg_cron, the SQL
-- Editor, and SECURITY DEFINER functions. The PulseMarket team can
-- still fix data by hand from the SQL Editor. App users always have
-- a JWT, so the skip never opens a door for them.
--
-- No new environment variables. No Paystack code. No theme change.
-- Run AFTER milestones 3–13 (it references their tables).

-- ---------------------------------------------------------------------------
-- 0) Helper: is the caller the PulseMarket team account?
-- ---------------------------------------------------------------------------
create or replace function public.pm_is_owner()
returns boolean
language sql
stable
as $$
  select coalesce((auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com', false);
$$;

-- ---------------------------------------------------------------------------
-- 1) Handoff codes move out of orders (see header, point 1).
--    handoff_codes: one row per meet-in-person order, seller-only.
-- ---------------------------------------------------------------------------
create table if not exists public.handoff_codes (
  order_id uuid primary key references public.orders (id) on delete cascade,
  code text not null,
  created_at timestamptz not null default now()
);

alter table public.handoff_codes enable row level security;

-- Only the seller of the order (or the team) can read its code.
-- The buyer asking for it gets no row back — never the code.
drop policy if exists "Sellers read their own handoff codes" on public.handoff_codes;
create policy "Sellers read their own handoff codes"
  on public.handoff_codes for select
  using (
    public.pm_is_owner()
    or exists (
      select 1 from public.orders o
      where o.id = handoff_codes.order_id
        and o.seller_id = auth.uid()
    )
  );

-- Only the seller of the order can create its code.
drop policy if exists "Sellers create their own handoff codes" on public.handoff_codes;
create policy "Sellers create their own handoff codes"
  on public.handoff_codes for insert
  with check (
    exists (
      select 1 from public.orders o
      where o.id = handoff_codes.order_id
        and o.seller_id = auth.uid()
    )
  );

-- No update or delete policy on purpose: a code is one-time per deal
-- and is never changed or removed by the app.

-- Copy every code issued so far, then empty the old column. Orders
-- placed after this file runs never write a code to orders at all
-- (the app writes handoff_codes; the trigger in section 3 refuses
-- any other value there).
insert into public.handoff_codes (order_id, code)
select id, seller_code from public.orders where seller_code is not null
on conflict (order_id) do nothing;

update public.orders set seller_code = null where seller_code is not null;

-- ---------------------------------------------------------------------------
-- 2) verify_seller_code RPC — the ONLY way to check a handoff code.
--    SECURITY DEFINER so it can read the code and write the scan /
--    attempts / lock / flag, but it never returns the code itself:
--    true on a match, false on a wrong code. A wrong code MUST NOT
--    raise: the attempt count, the lock and the log rows are written
--    first, and an exception would roll the whole call back and the
--    count would never stick — so a wrong code returns false and the
--    app re-reads the order to say how many tries are left (or that
--    the handoff locked). Only problems found BEFORE any write
--    (not signed in, no code yet, already scanned, already locked,
--    not the buyer) raise, because nothing has been written yet.
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

  select * into v_order from public.orders where id = p_order_id;
  if not found then
    raise exception 'Order not found.';
  end if;
  if v_order.delivery_method <> 'meetup' then
    raise exception 'This handoff is only for meet-in-person orders.';
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

  -- From here on the orders trigger (section 3) would refuse these
  -- writes from an app user, so the flag below tells it this change
  -- came from the code check itself. The flag is transaction-local
  -- (set_config ... true) and cannot be set through the API.
  perform set_config('pulsemarket.handoff_rpc', 'true', true);

  if v_typed = v_code then
    update public.orders
    set handoff_scanned_at = now(), updated_at = now()
    where id = p_order_id;
    return true;
  end if;

  -- Wrong code: count it, log it, lock at 5 and flag the account —
  -- then return false (never raise here: see the header note above,
  -- an exception would undo the counting).
  v_attempts := coalesce(v_order.code_attempts, 0) + 1;
  if v_attempts >= 5 then
    update public.orders
    set code_attempts = v_attempts, handoff_locked = true, updated_at = now()
    where id = p_order_id;
    update public.verifications set flagged = true where user_id = auth.uid();
    insert into public.security_log (user_id, order_id, action, detail)
    values (auth.uid(), p_order_id, 'wrong_code',
            'Wrong seller code attempt ' || v_attempts || ' of 5 for order ' || v_order.code || '.');
    insert into public.security_log (user_id, order_id, action, detail)
    values (auth.uid(), p_order_id, 'handoff_locked',
            'Handoff locked after ' || v_attempts || ' wrong seller codes for order ' || v_order.code || '.');
  else
    update public.orders
    set code_attempts = v_attempts, updated_at = now()
    where id = p_order_id;
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
-- 3) Orders — validate new orders and every status / field change.
--    (Header points 2 and 1: the old UPDATE policy let any participant
--    rewrite any field; these triggers are the real enforcement.)
-- ---------------------------------------------------------------------------

-- Unboxing-video check for the delivery gate. Returns true when the
-- evidence table is not there yet, so a missing Milestone 9 migration
-- fails open exactly like the app does — a missing table must not
-- block a real delivery.
create or replace function public.pm_has_verified_unboxing(p_order_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ok boolean;
begin
  if to_regclass('public.evidence') is null then
    return true;
  end if;
  select exists (
    select 1 from public.evidence
    where order_id = p_order_id
      and kind = 'unboxing'
      and media_type = 'video'
      and verified = true
  ) into v_ok;
  return coalesce(v_ok, false);
exception when undefined_table then
  return true;
end;
$$;

-- New orders: price matches the listing, fees match the fee rules
-- (src/lib/fees.js feeBreakdown), shipping is a set zone fee, and a
-- new order always starts 'reserved' with no history attached.
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

  select * into v_listing from public.listings where id = NEW.listing_id;
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
  elsif NEW.delivery_method = 'shipping' then
    if NEW.shipping_fee not in (1500, 2500, 3500) then
      raise exception 'The shipping fee must be one of the set zone fees (1500, 2500 or 3500).';
    end if;
    if NEW.ship_to_state is null or btrim(NEW.ship_to_state) = '' then
      raise exception 'Choose the state to ship to.';
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_order_insert_trg on public.orders;
create trigger pm_validate_order_insert_trg
  before insert on public.orders
  for each row execute function public.pm_validate_order_insert();

-- Every update: money/identity fields are frozen, status moves follow
-- the table below with the right actor, delivery/release re-check the
-- handoff and unboxing gates, and each side can only touch its own
-- handoff photo / confirmation / return step.
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
begin
  if v_uid is null then
    return NEW;
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

  -- The seller code never lives on the order any more (section 1).
  if NEW.seller_code is not null then
    raise exception 'Seller codes are stored in the handoff table, not on the order.';
  end if;

  -- 2) Timestamps only move with the status move they belong to.
  if NEW.paid_at is distinct from OLD.paid_at
    and not (OLD.status = 'reserved' and NEW.status = 'paid') then
    raise exception 'paid_at can only be set when the order is marked paid.';
  end if;
  if NEW.held_at is distinct from OLD.held_at
    and not (OLD.status = 'paid' and NEW.status = 'held') then
    raise exception 'held_at can only be set when the transfer is confirmed.';
  end if;
  if NEW.delivered_at is distinct from OLD.delivered_at
    and not (NEW.status = 'delivered') then
    raise exception 'delivered_at can only be set when delivery is confirmed.';
  end if;
  if NEW.released_at is distinct from OLD.released_at
    and not (NEW.status = 'released') then
    raise exception 'released_at can only be set when the money is released.';
  end if;

  -- 3) Frozen money does not move at all until the team resolves the
  -- dispute and unfreezes the order.
  if coalesce(OLD.frozen, false) and NEW.status is distinct from OLD.status then
    raise exception 'This order is frozen — a dispute is open. The PulseMarket team resolves it first.';
  end if;

  -- 4) Status moves: only the listed actor may make each move.
  if NEW.status is distinct from OLD.status then
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
  end if;

  -- 5) Handoff scan / attempts / lock: only the server-side code
  -- check (verify_seller_code, section 2) or the team may write
  -- these. A buyer typing the code into a direct API call cannot
  -- mark their own handoff scanned.
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
  -- (the URL pattern the app's own uploads produce).
  if NEW.handoff_photo_buyer is distinct from OLD.handoff_photo_buyer then
    if not v_is_buyer then
      raise exception 'Only the buyer can set the buyer handoff photo.';
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
  if NEW.delivery_pin is distinct from OLD.delivery_pin
    or NEW.waybill_number is distinct from OLD.waybill_number
    or NEW.waybill_photo is distinct from OLD.waybill_photo
    or NEW.receipt_photo is distinct from OLD.receipt_photo
    or NEW.driver_phone is distinct from OLD.driver_phone
    or NEW.shipping_proof_at is distinct from OLD.shipping_proof_at
    or NEW.shipping_advance_released is distinct from OLD.shipping_advance_released
  then
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
-- 4) Listings — participants may only flip the status, and only
--    verified students may post. (Header point 8.)
--
-- Why a new policy is needed at all: createOrder (buyer) reserves
-- the listing, releaseOrder / confirmDelivery (buyer) mark it sold,
-- and cancelOrder (buyer) puts it back to active — but the old
-- seller-only UPDATE policy refused all of those, so every
-- buyer-side order step failed at its last line. The policy below
-- lets order participants update the row; the trigger makes sure a
-- non-seller can change NOTHING but the status.
-- ---------------------------------------------------------------------------
drop policy if exists "Order participants update listing status" on public.listings;
create policy "Order participants update listing status"
  on public.listings for update
  using (
    public.pm_is_owner()
    or auth.uid() = seller_id
    or exists (
      select 1 from public.orders o
      where o.listing_id = listings.id
        and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
    )
  )
  with check (
    public.pm_is_owner()
    or auth.uid() = seller_id
    or exists (
      select 1 from public.orders o
      where o.listing_id = listings.id
        and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
    )
  );

-- Only the seller edits their listing. Anyone else (an order
-- participant, or the team) may change only the status, only between
-- active / reserved / sold, and only while an order links them to it.
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
  if auth.uid() = OLD.seller_id or public.pm_is_owner() then
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

-- Only verified students post: the seller must have a verification
-- row, the same gate the Sell page already applies in the app.
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
    select 1 from public.verifications v where v.user_id = NEW.seller_id
  ) then
    raise exception 'Only verified students can post a listing — finish verification first.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_listing_insert_trg on public.listings;
create trigger pm_validate_listing_insert_trg
  before insert on public.listings
  for each row execute function public.pm_validate_listing_insert();

-- ---------------------------------------------------------------------------
-- 5) Wallet ledger — one of each money move per order, and every row
--    checked against the order. (Header point 3.)
--    The app writes ledger rows in pairs (held -X / available +X);
--    the unique indexes below allow exactly one pair of each kind,
--    so a double-click, a retry, or two racing devices can never pay
--    twice — the second insert fails with a unique violation.
-- ---------------------------------------------------------------------------
create unique index if not exists wallet_ledger_one_hold_idx
  on public.wallet_ledger (order_id) where kind = 'hold';
create unique index if not exists wallet_ledger_one_release_idx
  on public.wallet_ledger (order_id, bucket) where kind = 'release';
create unique index if not exists wallet_ledger_one_advance_idx
  on public.wallet_ledger (order_id, bucket) where kind = 'shipping_advance';
create unique index if not exists wallet_ledger_one_refund_idx
  on public.wallet_ledger (order_id, bucket) where kind = 'refund';

-- Every ledger row must match the order it belongs to. Amounts are
-- re-derived here from the order, never trusted from the caller.
-- (The waybill/receipt presence for the advance is NOT re-checked
-- here: the app writes the advance before it saves the proof fields
-- on the order, so at insert time those fields are still empty. The
-- courier and the amount are checked; the receipt rule stays an
-- app-side check in submitShippingProof.)
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

  if NEW.kind = 'hold' then
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
    if NEW.bucket = 'held' then
      if NEW.amount <> -(v_order.total - v_advance) then
        raise exception 'A release must take exactly what is still held (total minus any advance already paid).';
      end if;
    elsif NEW.bucket = 'available' then
      -- The full release, or the remaining-shipping leg of a
      -- buyer-fault return (the buyer gets the item price back, the
      -- seller keeps the rest of the shipping fee).
      if NEW.amount = greatest(v_order.item_price + v_order.shipping_fee - v_advance, 0) then
        null;
      elsif coalesce(v_order.return_status, '') = 'opened'
        and NEW.amount = greatest(v_order.shipping_fee - v_advance, 0) then
        null;
      else
        raise exception 'A release must pay the seller exactly the item price plus the shipping fee, minus any advance already paid.';
      end if;
    else
      raise exception 'A release moves money between held and available only.';
    end if;
  elsif NEW.kind = 'shipping_advance' then
    if v_order.payment_method <> 'held' or v_order.status <> 'held' then
      raise exception 'A shipping advance is only paid while the money is held.';
    end if;
    if v_order.courier not in ('GIG Logistics', 'GUO Transport', 'DHL Domestic', 'Peace Logistics', 'ABC Transport') then
      raise exception 'This courier never earns a shipping advance.';
    end if;
    if NEW.user_id <> v_order.seller_id then
      raise exception 'A shipping advance pays the seller of the order.';
    end if;
    v_half := v_order.shipping_fee / 2;
    if NEW.bucket = 'held' and NEW.amount <> -v_half then
      raise exception 'A shipping advance moves exactly half the shipping fee out of hold.';
    elsif NEW.bucket = 'available' and NEW.amount <> v_half then
      raise exception 'A shipping advance pays exactly half the shipping fee.';
    elsif NEW.bucket not in ('held', 'available') then
      raise exception 'A shipping advance moves money between held and available only.';
    end if;
  elsif NEW.kind = 'refund' then
    if NEW.bucket = 'held' then
      if NEW.user_id <> v_order.seller_id
        or NEW.amount <> -(v_order.total - v_advance) then
        raise exception 'A refund must take exactly what is still held (total minus any advance already paid).';
      end if;
    elsif NEW.bucket = 'available' then
      if NEW.user_id <> v_order.buyer_id
        or NEW.amount < 0
        or NEW.amount > v_order.item_price + v_order.shipping_fee then
        raise exception 'A refund pays the buyer at most the item price plus the shipping fee.';
      end if;
    else
      raise exception 'A refund moves money between held and available only.';
    end if;
  elsif NEW.kind = 'debt' then
    if NEW.order_id is not null and NEW.user_id <> v_order.seller_id then
      raise exception 'A seller debt belongs to the seller of the order.';
    end if;
    if NEW.bucket <> 'available' or NEW.amount >= 0 then
      raise exception 'A seller debt is a negative available entry.';
    end if;
  elsif NEW.kind = 'repayment' then
    if NEW.order_id is not null and NEW.user_id <> v_order.seller_id then
      raise exception 'A repayment belongs to the seller who owed the debt.';
    end if;
    if NEW.bucket <> 'available' or NEW.amount <= 0 then
      raise exception 'A repayment is a positive available entry.';
    end if;
  elsif NEW.kind = 'withdrawal' then
    if NEW.bucket <> 'available' or NEW.amount >= 0
      or NEW.user_id <> auth.uid() then
      raise exception 'A withdrawal takes money out of your own available balance.';
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
-- 6) Verifications — a student can never mark themselves verified
--    or flag/unflag themselves. (Header point 4.) Only the team
--    changes status / flagged (from the dashboard — there is no app
--    UI for it). The handoff lock still flags accounts: it runs
--    inside verify_seller_code, which sets the transaction flag the
--    trigger below recognises.
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
  return NEW;
end;
$$;

drop trigger if exists pm_validate_verification_update_trg on public.verifications;
create trigger pm_validate_verification_update_trg
  before update on public.verifications
  for each row execute function public.pm_validate_verification_update();

-- ---------------------------------------------------------------------------
-- 7) Evidence — the database recomputes the verified tick on every
--    insert and ignores whatever the caller claimed. (Header point 5.)
--    The rules mirror src/lib/evidence.js verifyEvidenceRow exactly.
--    There is no UPDATE policy on evidence, so a tick can never be
--    flipped after the row exists.
-- ---------------------------------------------------------------------------
create or replace function public.pm_verify_evidence_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_seconds integer;
begin
  if auth.uid() is null then
    return NEW;
  end if;

  if NEW.kind in ('handoff', 'waybill', 'receipt', 'return') then
    -- Photo kinds: a photo present is enough; videos never count.
    NEW.duration_seconds := null;
    if NEW.media_type <> 'photo' then
      NEW.verified := false;
      NEW.verified_reason := 'This must be a photo, not a video.';
    else
      NEW.verified := true;
      NEW.verified_reason := null;
    end if;
    return NEW;
  end if;

  -- Video kinds.
  if NEW.media_type <> 'video' then
    NEW.verified := false;
    NEW.verified_reason := 'This must be a video — record it in the app.';
    return NEW;
  end if;
  if NEW.duration_seconds is null then
    NEW.verified := false;
    NEW.verified_reason := 'Could not measure the video length.';
    return NEW;
  end if;
  v_seconds := NEW.duration_seconds;

  if NEW.kind = 'dispute' then
    if v_seconds < 10 or v_seconds > 20 then
      NEW.verified := false;
      NEW.verified_reason := 'Video is ' || v_seconds || 's — dispute evidence must be 10–20s.';
    else
      NEW.verified := true;
      NEW.verified_reason := null;
    end if;
  elsif NEW.kind = 'packing' then
    if v_seconds < 15 or v_seconds > 30 then
      NEW.verified := false;
      NEW.verified_reason := 'Video is ' || v_seconds || 's — packing video must be 15–30s.';
    else
      NEW.verified := true;
      NEW.verified_reason := null;
    end if;
  elsif NEW.kind = 'unboxing' then
    if v_seconds <= 0 or v_seconds > 60 then
      NEW.verified := false;
      NEW.verified_reason := 'Video is ' || v_seconds || 's — unboxing video must be no longer than 60 seconds.';
    else
      NEW.verified := true;
      NEW.verified_reason := null;
    end if;
  else
    NEW.verified := false;
    NEW.verified_reason := 'Unknown evidence kind.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_verify_evidence_insert_trg on public.evidence;
create trigger pm_verify_evidence_insert_trg
  before insert on public.evidence
  for each row execute function public.pm_verify_evidence_insert();

-- ---------------------------------------------------------------------------
-- 8) Chat — conversations and offers. (Header point 6.)
--    A conversation can only be started by the buyer, for a listing
--    whose seller really is the named seller, never with yourself.
--    Messages cannot be edited, and only the OTHER participant may
--    accept or decline a pending offer — accepting your own offer to
--    set the agreed price is gone. An agreed price must match an
--    offer the other side actually accepted.
-- ---------------------------------------------------------------------------
drop policy if exists "Participants start conversations" on public.conversations;
create policy "Participants start conversations"
  on public.conversations for insert
  with check (
    auth.uid() = buyer_id
    and buyer_id <> seller_id
    and exists (
      select 1 from public.listings l
      where l.id = conversations.listing_id
        and l.seller_id = conversations.seller_id
    )
  );

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
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_message_update_trg on public.messages;
create trigger pm_validate_message_update_trg
  before update on public.messages
  for each row execute function public.pm_validate_message_update();

-- Messages are capped at 1000 characters in the app; cap them in the
-- database too (NOT VALID so old rows never block the migration).
do $$
begin
  alter table public.messages
    add constraint messages_body_max_1000
    check (char_length(body) <= 1000) not valid;
exception when duplicate_object then
  null;
end $$;

-- ---------------------------------------------------------------------------
-- 9) insert_notification RPC — the recipient must now be the other
--    participant, the caller themselves, or the team. (Header point 7.)
--    The old version let any participant of an order/conversation
--    notify ANY user, which is inbox spam aimed at a stranger.
-- ---------------------------------------------------------------------------
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

  insert into public.notifications (user_id, kind, title, body, link)
  values (p_user_id, p_kind, btrim(p_title), nullif(btrim(coalesce(p_body, '')), ''), nullif(btrim(coalesce(p_link, '')), ''))
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.insert_notification(uuid, text, text, text, text, uuid, uuid) from public;
grant execute on function public.insert_notification(uuid, text, text, text, text, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 10) Small hardening. (Header point 9.)
-- ---------------------------------------------------------------------------

-- Security-log rows can no longer be filed under somebody else's
-- user id: the row's user_id must be empty or the caller themselves.
drop policy if exists "Order participants log security events" on public.security_log;
create policy "Order participants log security events"
  on public.security_log for insert
  with check (
    (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
    or (
      (security_log.user_id is null or security_log.user_id = auth.uid())
      and exists (
        select 1 from public.orders o
        where o.id = security_log.order_id
          and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
      )
    )
  );

-- A reporter can delete only their own OPEN dispute. This also makes
-- fileDispute's own freeze-failure cleanup work: until now there was
-- no delete policy at all, so that cleanup was silently refused and
-- a failed freeze could leave an open report on unfrozen money.
drop policy if exists "Reporters retract their own open disputes" on public.disputes;
create policy "Reporters retract their own open disputes"
  on public.disputes for delete
  using (auth.uid() = reporter_id and status = 'open');

-- Nobody can block themselves.
do $$
begin
  alter table public.blocked_users
    add constraint blocked_users_not_self
    check (blocker_id <> blocked_id) not valid;
exception when duplicate_object then
  null;
end $$;

-- Rating comments are capped at 280 characters in the app; cap them
-- in the database too.
do $$
begin
  alter table public.ratings
    add constraint ratings_comment_max_280
    check (comment is null or char_length(comment) <= 280) not valid;
exception when duplicate_object then
  null;
end $$;

-- ---------------------------------------------------------------------------
-- Done. Verify in the SQL Editor with:
--   select * from public.handoff_codes;  -- codes moved out of orders
-- and re-test checkout -> pay -> ship -> deliver -> release in the app.
-- If the team ever needs a manual correction that a trigger refuses,
-- do it from the SQL Editor (no signed-in user there, so the triggers
-- step aside) — never by weakening these rules.
-- ---------------------------------------------------------------------------
