-- ===========================================================================
-- Milestone 23 — Night deep-check fixes (2026-11-27 run).
--
-- HOW TO RUN (code first, then SQL, only after Richard approves):
--   1. Push the app code first. Milestone 20/21/22 code + SQL must
--      already be live (code pushed 2026-11-27, SQL run 2026-11-27).
--   2. Run this file ONCE in the Supabase SQL Editor. Do NOT run it
--      before M20/M21/M22: §1/§4/§5/§7/§14 replace functions those
--      milestones install.
--   3. Expected result: "Success. No rows returned" (notices about
--      skipped index blocks are fine — they mean duplicates already
--      existed; see the pre-run checks below).
--
-- PRE-RUN CHECKS (run these in the SQL Editor first; each must
-- return 0 rows — fix by hand if any return rows):
--   a. Duplicate open disputes per order (the M16 one-open-dispute
--      index must already hold; if it does not, resolve them first):
--        select order_id, count(*) from public.disputes
--        where status in ('open', 'under_review')
--        group by order_id having count(*) > 1;
--   b. Released orders missing a release leg (§4 repair — note the
--      codes; release_order() completes the missing leg once this
--      file has run, and the app-side reconcile tool closes them):
--        select o.id, o.code,
--          exists(select 1 from public.wallet_ledger
--            where order_id = o.id and kind = 'release'
--            and bucket = 'held') as has_held,
--          exists(select 1 from public.wallet_ledger
--            where order_id = o.id and kind = 'release'
--            and bucket = 'available') as has_avail
--        from public.orders o where o.status = 'released'
--          and (not exists(select 1 from public.wallet_ledger
--              where order_id = o.id and kind = 'release'
--              and bucket = 'held')
--            or not exists(select 1 from public.wallet_ledger
--              where order_id = o.id and kind = 'release'
--              and bucket = 'available'));
--
-- WHAT IT FIXES (each section says which):
--   §1  (a) An expired boost locked the seller out of editing their
--       own listing — the boost checks ran on every update, not
--       only when the boost changed. (b) A seller could mark a
--       listing Sold/Reserved while an order was open on it — the
--       seller branch of the listing trigger never checked.
--   §2  Deleting an open dispute left the order frozen for ever,
--       with no dispute left to resolve. (Validation caught that
--       the §2 unfreeze itself was refused when the deleter was
--       the buyer — fixed by the §14 flag; see §14.)
--   §3  Any order/chat participant could send fake 'dispute'
--       notifications ("your money is frozen") that bypassed the
--       recipient's prefs entirely.
--   §4  A 'released' order missing one release leg had no repair
--       path — the seller's money was stranded.
--   §5  Two opposite offer accepts could deadlock instead of
--       failing cleanly; an offer above the asking price could be
--       accepted and set a false agreed price.
--   §6  The pickup-insert trigger had the same stranger
--       fall-through M22 §5/§6 fixed in two other places, and a
--       ticket could point at any order.
--   §7  A pickup status-only change skipped the participation
--       check, so a stranger could flip a ticket's status.
--   §8  The security-log rate limit could be bypassed by logging
--       with user_id = NULL.
--   §9  Re-opening a resolved dispute did not re-freeze the order.
--   §10 A handoff could be scanned while a dispute was open.
--   §11 A paid → cancelled → paid flip re-applied a fresh boost,
--       and sold/reserved listings could be boosted.
--   §12 No change: waybill reuse was already blocked by the
--       Milestone 18 unique index on waybill_number alone — the
--       proposed (courier, waybill) index could never fire.
--       See the §12 comment in the file for the known
--       cross-courier limitation.
--   §13 Handoff scan/photos/confirmations could change while the
--       order was frozen — the meetup proof the team is reviewing.
--   §14 The order trigger's frozen-flag branch refused the §2/§9
--       dispute triggers' own flag flips when the caller was the
--       buyer (only the team may unfreeze) — so deleting your own
--       open dispute failed outright. The triggers now set a
--       transaction-local flag the order trigger honours.
--
-- APP CODE FIXED ALONGSIDE (same night run, local only until push):
--   Checkout blocks Reserve on a failed agreed-price read (it used
--   to silently charge full price); Dashboard "Mark sold/reserved"
--   refuses while an order is open; handoff scan/photo/confirm
--   refuse while frozen (+ frozen banner, + timestamped
--   'handoff_confirmed' security event); createOrder requires a
--   courier and enforces the GIG/GUO tier unconditionally, refuses
--   a missing conversation, and checks buyer verification in plain
--   words; submitShippingProof re-checks the tier and the waybill
--   across sellers; fileDispute returns the existing ticket on a
--   racing double-submit; legacy release refuses after a refund;
--   stuck-money tooling recognises delivered+refund; debt-write
--   failures surface their real cause; the return fault label is
--   only corrected after the double-resolve guard; checkpoints
--   refuse exact repeats / same-status spam; retryShippingAdvance
--   verifies the available leg after a 23505. See the run log.
--
-- IDEMPOTENT: every statement is CREATE OR REPLACE, DROP ... IF
-- EXISTS, or a guarded DO block. Safe to run twice.
-- NEVER re-run milestone-14 to milestone-18 after this file.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- §1)
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
    -- (Milestone 23) A status move by the seller is refused while an
    -- order is open on the listing — the order flows move the status
    -- themselves. The app guards this in ListingDetail and Dashboard
    -- (Milestone 22), but this trigger's seller branch never
    -- checked it, so a direct call could mark a listing Sold while
    -- the buyer's order and held money were still live (and a later
    -- cancel would silently flip it back to active). The team
    -- bypasses this, so a bad state can always be fixed by hand.
    -- 'Open' is reserved/paid/held/shipped/delivered. A delivered
    -- order has already closed the sale through the order flow, and
    -- a released order is not open at all, so marking sold after a
    -- release still works.
    if not public.pm_is_owner()
      and NEW.status is distinct from OLD.status
      and exists (
        select 1 from public.orders o
        where o.listing_id = OLD.id
          and o.status in ('reserved', 'paid', 'held', 'shipped', 'delivered')
      ) then
      raise exception 'This listing has an open order — its status moves with the order, not by hand.';
    end if;
    -- (Milestone 23) These four checks used to run on EVERY seller
    -- or team update, not only when the boost changed — so 24h
    -- after a boost expired, the seller could not edit their own
    -- listing at all (every update hit "A boost can last at most
    -- 72 hours"). They now run only when a boost column actually
    -- changes. An expired boost left on the row is harmless: the
    -- app treats it as not-live, and buying a new boost overwrites
    -- it. (Same rule pm_validate_listing_values already uses: only
    -- validate a column that actually changed, so an old row with
    -- a stale value is never blocked from an unrelated edit.)
    if NEW.boost_tier is distinct from OLD.boost_tier
      or NEW.boosted_until is distinct from OLD.boosted_until then
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
-- §2)
-- ---------------------------------------------------------------------------
create or replace function public.pm_unfreeze_on_dispute_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- (Milestone 23) Deleting an open dispute used to leave the order
  -- frozen for ever: the freeze fires on INSERT and the unfreeze on
  -- UPDATE to 'resolved', and nothing ran on DELETE. A buyer could
  -- delete their own open dispute (the M14 policy allows it) and
  -- strand the money with no dispute left for the team to see or
  -- resolve. Unfreeze here — but only when no OTHER open dispute
  -- remains on the order (with the M16 one-open-dispute index there
  -- can never be another, but the check costs nothing and stays
  -- correct if the index is ever dropped). The fileDispute cleanup
  -- path deletes a dispute only when the order is NOT frozen, so
  -- this is a no-op for it.
  -- (Validation fix) The unfreeze below runs with the DELETER's
  -- identity — usually the buyer — and pm_validate_order_update
  -- §6 refuses a non-team unfreeze, so without the flag this
  -- whole DELETE failed with "Only the PulseMarket team can
  -- change the frozen flag." Set the transaction-local flag
  -- first (§14 honours it); it dies with the transaction and
  -- cannot be set through the API, same as the handoff_rpc flag.
  if OLD.status in ('open', 'under_review') and OLD.order_id is not null then
    if not exists (
      select 1 from public.disputes d
      where d.order_id = OLD.order_id
        and d.id <> OLD.id
        and d.status in ('open', 'under_review')
    ) then
      perform set_config('pulsemarket.unfreeze_rpc', 'true', true);
      update public.orders
      set frozen = false, updated_at = now()
      where id = OLD.order_id and coalesce(frozen, false);
    end if;
  end if;
  return OLD;
end;
$$;

drop trigger if exists pm_unfreeze_on_dispute_delete_trg on public.disputes;
create trigger pm_unfreeze_on_dispute_delete_trg
  after delete on public.disputes
  for each row execute function public.pm_unfreeze_on_dispute_delete();

-- ---------------------------------------------------------------------------
-- §3)
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

  -- (Milestone 23) Fake 'dispute' notices: kind 'dispute' used to
  -- need no order state at all — any order/chat participant could
  -- send a 'dispute' notification with arbitrary title/body to the
  -- other party, and the D-2 prefs bypass below meant it landed
  -- even when the recipient turned dispute notices off. A buyer or
  -- seller could send "Your money is frozen" notices that are
  -- indistinguishable from real ones. A non-team caller must now
  -- point at an order with a genuinely open dispute or an open
  -- return. The team stays exempt (refund / resolve notices).
  -- Legit non-team sends, both checked: the buyer's "Return
  -- opened" notice (shipping.js openReturn, sent after the return
  -- opens) and any 'dispute' notice sent with an open dispute on
  -- the order. A notification with no order at all is refused.
  if p_kind = 'dispute' and not public.pm_is_owner() then
    if p_order_id is null
      or not exists (
        select 1 from public.orders o
        where o.id = p_order_id
          and (coalesce(o.return_status, '') = 'opened'
               or exists (
                 select 1 from public.disputes d
                 where d.order_id = o.id
                   and d.status in ('open', 'under_review')
               ))
      ) then
      raise exception 'A dispute notification needs an open dispute or an open return on that order.';
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
-- §4a)
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
    -- (Milestone 23) A released order missing ONE leg is a pre-M19
    -- half-move (or a crash between the two leg writes): complete
    -- the missing leg instead of stranding the seller's money with
    -- no repair path. The existing leg is verified against the
    -- expected amount first, and only the missing leg is written.
    -- Buyer or team only. The ledger trigger (§4b) accepts a
    -- release leg on a released order only when it completes a
    -- missing leg, so no other path can use this to pay twice.
    if v_has_held_leg or v_has_avail_leg then
      if not (v_caller = v_order.buyer_id or public.pm_is_owner()) then
        raise exception 'Only the buyer or the PulseMarket team can complete this release.';
      end if;
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
      update public.listings
      set status = 'sold'
      where id = v_order.listing_id
        and status = 'reserved';
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
-- §4b)
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
      -- (Milestone 23) A release held leg is also allowed on a
      -- 'released' order when it completes a missing leg — the
      -- available leg is already there with the right amount
      -- (release_order §4a verifies it before writing). Any other
      -- released-order release is still refused.
      if v_order.status <> 'delivered'
        and not (
          v_order.status = 'released'
          and exists (
            select 1 from public.wallet_ledger
            where order_id = NEW.order_id and kind = 'release' and bucket = 'available'
              and amount = greatest(v_order.item_price + v_order.shipping_fee - v_advance, 0)
          )
        ) then
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
        -- (Milestone 23) Same completion allowance as the held leg
        -- above: a 'released' order may gain its missing available
        -- leg when the held leg is already there with the right
        -- amount (release_order §4a verifies it first).
        if v_order.status <> 'delivered'
          and not (
            v_order.status = 'released'
            and exists (
              select 1 from public.wallet_ledger
              where order_id = NEW.order_id and kind = 'release' and bucket = 'held'
                and amount = -(v_order.total - v_advance)
            )
          ) then
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
-- §5)
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
  v_conv_id uuid;
  v_listing_id uuid;
  v_listing_price integer;
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

  -- (Milestone 23) Lock the conversation row FIRST, then the
  -- message row. The old order (message first, conversation
  -- second) could deadlock on two opposite accepts: each locked a
  -- different message row, then each waited on the other's lock
  -- (one on the conversation row, one on the message row in the
  -- mass-decline below). Locking the conversation first
  -- serialises all answers in one conversation. The message is
  -- still re-checked after its lock below, because another answer
  -- could have landed between the unlocked read here and the
  -- message lock.
  select conversation_id into v_conv_id
  from public.messages
  where id = p_message_id;
  if v_conv_id is null then
    raise exception 'Offer not found.';
  end if;
  select buyer_id, seller_id, listing_id into v_buyer, v_seller, v_listing_id
  from public.conversations
  where id = v_conv_id
  for update;
  if v_buyer is null then
    raise exception 'That offer has no conversation.';
  end if;

  -- Lock the message row: concurrent answers queue here, so
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
  -- (Milestone 23) An offer above the asking price must never be
  -- accepted: it would set an agreed price above the listing price
  -- that checkout caps back down, so the chat banner promises a
  -- price nobody charges. The app refuses it in sendOffer too.
  if p_status = 'accepted' then
    select price into v_listing_price
    from public.listings
    where id = v_listing_id;
    if v_listing_price is not null and v_msg.offer_amount > v_listing_price then
      raise exception 'An offer cannot be more than the asking price.';
    end if;
  end if;

  -- (Milestone 23) The conversation row is already locked above
  -- (before the message row) — see the lock-order note there.
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
-- §6)
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
  -- (Milestone 23) The old check never fired for a stranger: when
  -- the caller is neither buyer nor seller, the CASE falls through
  -- to the buyer, so v_other was non-null and no error was raised
  -- — the exact bug M22 §5/§6 fixed in the message-insert and
  -- pickup-update triggers. Check membership directly (RLS
  -- backstops it live, but the trigger must not depend on that).
  -- v_other is still computed below for the blocked check.
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
  -- (M19) Later-rejected / flagged: no new meetup plans in a chat
  -- where either side is no longer an approved, unflagged student.
  select c.buyer_id, c.seller_id into v_buyer, v_seller
    from public.conversations c
    where c.id = NEW.conversation_id;
  if not public.pm_chat_verification_ok(v_buyer, v_seller) then
    raise exception 'You cannot plan a meetup with this student — one of the students in this chat is no longer verified.';
  end if;
  -- (Milestone 23) A ticket must point at an order of this
  -- conversation's listing (or at no order at all) — it used to be
  -- able to point at any order, or none, with no check.
  if NEW.order_id is not null
    and not exists (
      select 1 from public.orders o
      join public.conversations c on c.listing_id = o.listing_id
      where o.id = NEW.order_id
        and c.id = NEW.conversation_id
    ) then
    raise exception 'A pickup ticket must point at an order for this conversation.';
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
-- §7)
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
  -- (Milestone 23) The participation check runs BEFORE the
  -- status-only early return below: the old order let a
  -- status-only change (scheduled -> done/cancelled) skip the
  -- participation check entirely, so a stranger could flip a
  -- ticket's status. The M19 comment says status-only changes
  -- skip the *verification* gate; skipping the *participation*
  -- check as well was never the intent.
  if not exists (
    select 1 from public.conversations
    where id = NEW.conversation_id
      and (buyer_id = auth.uid() or seller_id = auth.uid())
  ) then
    raise exception 'You are not part of this conversation.';
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
-- §8)
-- ---------------------------------------------------------------------------
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
  -- (Milestone 23) The old count missed rows logged with
  -- user_id = NULL — the M14 insert policy explicitly allows NULL
  -- — so a participant could flood the log with NULL rows and
  -- never trip the 20/minute limit, the exact flood this limit was
  -- built to stop. Count those too. (A NULL row belongs to no one,
  -- so it counts against every caller's limit — that is what stops
  -- the flood.)
  select count(*) into v_count
    from public.security_log
    where (user_id = auth.uid() or user_id is null)
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

-- ---------------------------------------------------------------------------
-- §9)
-- ---------------------------------------------------------------------------
create or replace function public.pm_refreeze_on_dispute_reopen()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- (Milestone 23) A resolved dispute moved back to open (or under
  -- review) never re-froze the order: the freeze fires on INSERT
  -- only, and the unfreeze already ran on resolve — so the order
  -- sat unfrozen with a live dispute and auto-release could pay
  -- out. Re-freeze here. (Filing a NEW dispute after resolution
  -- still works — it freezes on insert as before.)
  -- (Milestone 23) Same flag as §2 (§14 honours it): the re-freeze
  -- below runs with the updater's identity, and the flag keeps
  -- the order trigger's frozen-flag branch from refusing it.
  if NEW.status in ('open', 'under_review')
    and OLD.status = 'resolved'
    and NEW.order_id is not null then
    perform set_config('pulsemarket.unfreeze_rpc', 'true', true);
    update public.orders
    set frozen = true, updated_at = now()
    where id = NEW.order_id and coalesce(frozen, false) = false;
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_refreeze_on_dispute_reopen_trg on public.disputes;
create trigger pm_refreeze_on_dispute_reopen_trg
  after update on public.disputes
  for each row execute function public.pm_refreeze_on_dispute_reopen();

-- ---------------------------------------------------------------------------
-- §10)
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
  -- (Milestone 23) A frozen order (open dispute) must not be
  -- scanned: the code check is the first handoff step, and letting
  -- it through would let a seller get the buyer to scan after a
  -- "never received it" dispute was filed. The app refuses it too
  -- (handoff.js), and the handoff-fields trigger (§13) is the
  -- backstop for direct updates.
  if coalesce(v_order.frozen, false) then
    raise exception 'This order is frozen — a dispute is open. The PulseMarket team resolves it first.';
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
-- §11)
-- ---------------------------------------------------------------------------
create or replace function public.pm_apply_paid_boost()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status = 'paid' and OLD.status is distinct from 'paid' then
    -- (Milestone 23) Only boost a listing that is still active and
    -- has no live boost: the old code boosted sold/reserved
    -- listings too, and a paid → cancelled → paid flip re-applied
    -- a fresh 24h/72h without a new payment. (purchase_boost
    -- already refuses a new purchase while a boost is live and
    -- requires an active listing, so a legit paid purchase can
    -- never be skipped by these conditions.)
    update public.listings
      set boost_tier = NEW.tier,
          boosted_until = case
            when NEW.tier = 500 then now() + interval '24 hours'
            else now() + interval '72 hours'
          end
      where id = NEW.listing_id
        and status = 'active'
        and (boosted_until is null or boosted_until <= now());
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_apply_paid_boost_trg on public.boost_purchases;
create trigger pm_apply_paid_boost_trg
  after update on public.boost_purchases
  for each row execute function public.pm_apply_paid_boost();

-- ---------------------------------------------------------------------------
-- §12)
-- ---------------------------------------------------------------------------
-- Waybill reuse was flagged as a hole (the app checks it
-- best-effort in submitShippingProof, and the orders read policy
-- only shows a seller their own orders, so a cross-seller reuse
-- was thought invisible). Validation against the real chain found
-- Milestone 18 already closes it at the database: a unique index
-- on waybill_number alone (orders_waybill_number_unique_idx)
-- blocks the same number on ANY order, same courier or not — so
-- a (courier, waybill_number) index could never fire and is not
-- added here. The W12 tests below prove the M18 index holds.
-- Known limitation, for Richard to decide later: the M18 index
-- also blocks the same number across DIFFERENT couriers, which
-- could in theory be a coincidence (couriers number parcels
-- independently). Loosening it means dropping a live index, so
-- it is NOT done in this file.

-- ---------------------------------------------------------------------------
-- §13)
-- ---------------------------------------------------------------------------
create or replace function public.pm_freeze_handoff_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- (Milestone 23) No handoff evidence may change while the order
  -- is frozen (open dispute): the scan, photos and confirmations
  -- are the meetup proof the team is reviewing. Money cannot move
  -- while frozen (status moves and release are blocked), but the
  -- handoff fields are plain columns the old trigger left alone —
  -- a seller could get the buyer to scan + confirm after a
  -- "never received it" dispute was filed, and the team would see
  -- "handoff complete" with no way to know it happened after the
  -- filing. The team bypasses this (a bad state can always be
  -- fixed by hand), and the unfreeze itself only flips `frozen`,
  -- so this never blocks it. The verify_seller_code RPC refuses
  -- frozen scans on its own (§10); this is the backstop for
  -- direct updates. confirmHandoff also logs a timestamped
  -- 'handoff_confirmed' security event, so the team can see WHEN
  -- each side confirmed.
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
  end if;
  if coalesce(OLD.frozen, false)
    and (NEW.handoff_scanned_at is distinct from OLD.handoff_scanned_at
         or NEW.handoff_photo_buyer is distinct from OLD.handoff_photo_buyer
         or NEW.handoff_photo_seller is distinct from OLD.handoff_photo_seller
         or NEW.buyer_confirmed is distinct from OLD.buyer_confirmed
         or NEW.seller_confirmed is distinct from OLD.seller_confirmed) then
    raise exception 'This order is frozen — the handoff cannot change until the dispute is resolved.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_freeze_handoff_fields_trg on public.orders;
create trigger pm_freeze_handoff_fields_trg
  before update on public.orders
  for each row execute function public.pm_freeze_handoff_fields();

-- ---------------------------------------------------------------------------
-- §14)
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
  -- (Milestone 23) Set (transaction-local) by the dispute triggers
  -- in §2/§9 before THEY flip the frozen flag, so their updates
  -- pass the §6 branch below even when the caller is the buyer.
  v_via_unfreeze boolean := coalesce(current_setting('pulsemarket.unfreeze_rpc', true) = 'true', false);
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
    -- (Milestone 23) The dispute triggers set this flag
    -- (transaction-local) when THEY flip the flag — §2 unfreezing
    -- on delete, §9 re-freezing on re-open — so their updates pass
    -- even when the caller is the buyer deleting their own dispute.
    -- Without it, §2's whole DELETE failed here: the deleter is the
    -- buyer, and only the team may unfreeze. A caller cannot set
    -- the flag through the API (set_config is not exposed there),
    -- and it dies with the transaction — same as handoff_rpc.
    elsif v_via_unfreeze then
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
