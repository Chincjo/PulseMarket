-- ===========================================================================
-- Milestone 22 — Morning deep-check fixes (2026-11-27 run).
--
-- HOW TO RUN (code first, then SQL, only after Richard approves):
--   1. Push the app code first. Milestone 20's code must already be live.
--   2. Run milestone-20.sql, then milestone-21.sql, then this file, each
--      ONCE in the Supabase SQL Editor, in that order. Do NOT run it
--      before M20/M21: §9/§10 replace functions M18/M21 install.
--   3. After this file runs, the server-side 48h auto-release (§1) is
--      fixed — call select auto_release_overdue_orders() once by hand
--      and check it returns without error before scheduling it hourly
--      (pg_cron). It could never run before this fix.
--
-- WHAT IT FIXES (each section says which):
--   §1  CRITICAL: auto_release_overdue_orders() could never run at all
--       — its FOR query read o.frozen, but 'o' is the loop record and
--       is unassigned when the query starts, so every call raised
--       "record o is not assigned yet". The server-side 48h release
--       was dead; the app-side sweep was the only working path.
--   §2  A sender may now DECLINE (withdraw) their own offer; accepting
--       your own offer is still refused. Needed so §3 can decline the
--       acceptor's own pending offers without rolling the accept back.
--   §3  Accepting an offer now declines ALL other pending offers in
--       the conversation (M21 declined only the other student's, so
--       your own pending offers stayed open and could still be
--       accepted, leaving two 'accepted' offers) and locks the
--       conversation row, closing the simultaneous cross-accept race.
--   §4  The M21 team-correction branch (fix a wrong PIN / waybill /
--       driver phone) can no longer smuggle a
--       shipping_advance_released flip past the ledger check.
--   §5  The message-insert participation check never fired for a
--       stranger (the CASE fell through to the buyer, so v_other was
--       never null). Membership is now checked directly.
--   §6  Same participation fix for pickup-ticket updates.
--   §7  Checkpoint inserts now lock the order row, so two concurrent
--       checkpoints cannot both read the same "latest" row and pass.
--   §8  A 'repayment' (the seller paying a debt back in real cash) no
--       longer credits the seller's withdrawable balance: it now
--       lives in a new 'settled' bucket. The old positive 'available'
--       entry recreated the refunded advance as payable money — the
--       seller could have withdrawn the advance twice. The wallet
--       bucket CHECK is widened to include 'settled' first.
--   §9  A listing must use the seller's VERIFIED university (the
--       university is locked at verification). A UNIPORT-verified
--       student could post as "University of Lagos", breaking state
--       filtering, same-state rules and shipping zones.
--   §10 A non-seller may only move a listing's status as part of an
--       order flow, and the move must match their own order's state
--       ('reserved' while reserved/paid, 'sold' once
--       delivered/released, 'active' once cancelled/refunded with no
--       other open order). A buyer from a cancelled order months ago
--       could previously flip any live listing's status.
--
-- IDEMPOTENT: every statement is CREATE OR REPLACE, DROP ... IF
-- EXISTS, or a guarded DO block. Safe to run twice.
-- NEVER re-run milestone-14 to milestone-18 after this file.
-- NOTE: milestone-12.sql still carries the old auto-release copy with
-- the o.frozen bug — it is superseded (M20 replaces the function when
-- it runs) and is intentionally left untouched; do not re-run M12.
-- ===========================================================================
-- ---------------------------------------------------------------------------
-- §1) auto_release_overdue_orders(): alias the table 'ord' so the frozen guard reads the table, not the unassigned loop record.
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
-- §2) pm_validate_message_update(): a sender may decline (withdraw) their own offer; accepting it stays refused.
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
-- §3) respond_offer(): accepting declines ALL other pending offers and locks the conversation row.
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

-- ---------------------------------------------------------------------------
-- §4) pm_validate_order_update(): the team-correction branch can no longer flip shipping_advance_released.
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
-- §5) pm_validate_message_insert(): the participation check now actually fires for strangers.
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
-- §6) pm_validate_pickup_update(): same participation fix as §5.
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
-- §7) pm_validate_checkpoint_insert(): lock the order row before reading the latest checkpoint.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- §8) pm_validate_ledger_insert(): a repayment settles the debt from the 'settled' bucket — it must never credit the seller's withdrawable balance.
-- ---------------------------------------------------------------------------
-- The 'settled' bucket (see the repayment branch below) needs the
-- table CHECK widened first: milestone-6.sql only allows 'held' and
-- 'available'. The constraint name is found by definition instead of
-- assumed, so this stays safe if it was ever renamed. Idempotent:
-- dropping and re-adding the widened CHECK is a no-op for existing
-- rows (all are held/available).
do $$
declare
  v_conname text;
begin
  select conname into v_conname
  from pg_constraint
  where conrelid = 'public.wallet_ledger'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%bucket%';
  if v_conname is not null then
    execute format('alter table public.wallet_ledger drop constraint %I', v_conname);
  end if;
end $$;
alter table public.wallet_ledger
  add constraint wallet_ledger_bucket_check
  check (bucket in ('held', 'available', 'settled'));

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
-- §9) pm_validate_listing_insert(): a listing must use the seller's verified university.
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
  -- (Milestone 22) The university is locked at verification: a
  -- UNIPORT-verified student used to post as "University of Lagos",
  -- breaking state filtering, same-state rules and shipping zones.
  -- The app refuses it first (createListingRow); this is the
  -- backstop against a direct API call.
  if exists (
    select 1 from public.verifications v
    where v.user_id = NEW.seller_id
      and v.university is distinct from NEW.university
  ) then
    raise exception 'A listing must use your verified university.';
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
-- §10) pm_validate_listing_update(): a non-seller may only move the status as part of an order flow that matches their own order's state.
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

-- Done. Milestone 22.
