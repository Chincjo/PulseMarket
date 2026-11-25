-- PulseMarket Milestone 16 — THIRD AUDIT FIXES (SQL only).
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: every statement
-- below is idempotent (CREATE OR REPLACE, DROP IF EXISTS / DROP
-- TRIGGER IF EXISTS, CREATE POLICY after DROP POLICY IF EXISTS, or a
-- DO block that ignores "already exists"), so re-running it changes
-- nothing.
--
-- DEPLOY ORDER — READ THIS FIRST: no app code change is needed for
-- any fix in this file. Every fix below is pure SQL, and the app
-- already sends the shapes these fixes expect (paired ledger inserts,
-- refundHeldOrder, handoff photo retakes, tier-matched boosts). Run
-- this file AFTER supabase/milestone-15.sql has run. Do NOT re-run
-- milestone-15.sql after this file: its section E block drops EVERY
-- UPDATE policy on storage.objects that mentions evidence-media,
-- including the narrow handoff-photo policy restored in section 12
-- below — re-running 15 would silently break handoff photo retakes
-- again.
--
-- THIS FILE HAS NOT BEEN EXECUTED ANYWHERE. There is no Postgres in
-- the audit VM, so it was verified by re-reading only: $$ balance,
-- BEGIN/END matching, and a line-by-line diff of every reproduced
-- function against milestone-15.sql (only the documented changes
-- differ). Run it in the SQL Editor and re-test: buyer release after
-- a shipping advance, owner resolve-return after an advance, /admin
-- refund of a never-shipped held order, handoff photo retake, and a
-- two-account checkout -> pay -> hold -> ship -> deliver -> release.
--
-- WHAT THE THIRD AUDIT FOUND (all verified by reading the code, the
-- Milestone 14/15 SQL, and the app call sites in src/lib/*.js — no
-- live run was used):
--
--   F1. LEDGER READS ARE BLIND FOR BUYER AND OWNER. wallet_ledger's
--       only SELECT policy (Milestone 6) is "own rows only", so a
--       buyer or the team account reads ZERO rows for the seller's
--       ledger entries. advanceAlreadyReleased() therefore always
--       returns 0 for them, and releaseOrder (buyer) / resolveReturn
--       (owner) compute the wrong amounts whenever a shipping
--       advance was already paid — the server trigger then refuses
--       the move and the order is stuck (release only unblocks via
--       the 48h seller auto-release; a return refund has no such
--       escape). Fix: a participant-or-owner SELECT policy (§1).
--   F2. /admin REFUND OF A HELD ORDER IS DEAD. refundHeldOrder()
--       (src/lib/orders.js, used by /admin for an order the seller
--       never shipped) is refused twice by Milestone 15: the ledger
--       trigger demands an open return for a refund out of hold, and
--       the order trigger has no held -> refunded move. Fix:
--       owner-only held -> refunded, with matching ledger
--       exemptions for the exact amounts the app sends (§2, §4).
--   F3. A SINGLE HELD LEG CAN BE WRITTEN ALONE. The paired-leg
--       checks only ever look BACKWARD (an available leg needs its
--       held leg), so a participant can insert just the held leg of
--       a release / refund / advance: the money leaves hold with no
--       available credit, and the unique index then blocks the real
--       pair for ever. Fix: a deferred constraint trigger that
--       requires the available mate at transaction end (§3).
--   F4. THE HELD-SUM BACKSTOP IS RACEABLE. Milestone 15's "held sum
--       >= 0" check reads the sum without locking anything, so a
--       release and a refund (or two withdrawals) running at the
--       same time both pass and both commit — held goes negative.
--       Fix: lock the order row (FOR UPDATE) in the ledger trigger
--       and take an advisory lock for withdrawals (§2).
--   F5. MILESTONE 15 §E BREAKS HANDOFF PHOTO RETAKES.
--       uploadHandoffPhoto() uploads with upsert:true to a fixed
--       path (<user>/handoff-<order>-<role>.jpg), which needs the
--       storage UPDATE policy §E dropped. A retake is now refused.
--       Fix: a narrow UPDATE policy for the user's own handoff-*
--       files only; verified evidence-* files stay un-replaceable
--       (§12).
--   F6. FREE BOOST WITHOUT A TIER. A seller can set boosted_until
--       alone (tier NULL) and isBoosted() treats it as a live boost;
--       a ₦500 tier can also carry a 72h expiry. Fix: tier and
--       expiry must be set/cleared together, and the expiry must
--       match the tier (500 -> 24h, 1000 -> 72h, +1h clock-skew
--       tolerance) (§6).
--   F7. A DISPUTE CAN BE FILED WITH NO EVIDENCE. fileDispute()
--       requires a verified dispute video app-side, but the
--       database checks nothing on disputes inserts — a direct API
--       call files a report (and freezes the money) with no proof.
--       Fix: an insert trigger mirroring fileDispute's own checks
--       (§10).
--   F8. AN ORDER CAN USE A DELIVERY METHOD THE LISTING DOES NOT
--       OFFER, and a same_state listing can be shipped to another
--       state — both are app-only checks today. Fix: both rules in
--       the order-insert trigger (§5).
--   F9. THE SELLER'S OWN VIDEO PASSES THE UNBOXING GATE.
--       pm_has_verified_unboxing() accepts any participant's video,
--       so the seller can film an "unboxing" and certify their own
--       delivery. Fix: the video must belong to the buyer (§9).
--  F10. A NULL COURIER SLIPS PAST THE ADVANCE CHECK. `courier NOT
--       IN (...)` is NULL (not true) when courier is NULL, so the
--       check is skipped. Fix: an explicit NULL test (§2).
--  F11. A HOLD CAN BE RECORDED IN ANY ORDER STATUS. The hold branch
--       never checks the order is 'paid'. Fix: require status
--       'paid' (§2).
--  F12. DELETING A LISTING WIPES LIVE ORDERS. The app refuses to
--       delete a listing with non-cancelled orders, but the
--       database has no DELETE trigger — a direct API delete
--       cascades to orders, chats, checkpoints and evidence. Fix: a
--       BEFORE DELETE trigger mirroring the app's rule (§7).
--  F13. THE NOTIFICATION RATE LIMIT IS RACEABLE. Parallel RPC calls
--       all read the same count and all pass. Fix: serialise the
--       check per caller with an advisory lock (§11).
--  F14. student_email IS NOT IN THE IDENTITY LOCK. university /
--       student_id / invite_code are immutable, but the student
--       email can still be swapped after submit. Fix: lock it too
--       (§8). (chat_verified_only and referred_by are untouched —
--       Settings and saveVerificationRow still update those.)
--  F15. CHECKPOINTS HAVE NO STATUS GATE IN THE DB. addCheckpoint()
--       requires shipped/delivered app-side only. Fix: an insert
--       trigger (§13).
--  F16. PICKUP UPDATES ARE UNVALIDATED. Milestone 15 validated
--       pickup inserts only — an update can move a pickup to a past
--       date or an invented spot. Fix: an update trigger mirroring
--       the insert rules (§14).
--  F17. DISPUTE EVIDENCE CAN BE DELETED AFTER FILING. The buyer can
--       delete their dispute video while the report is open,
--       leaving the team with no proof. Fix: a delete trigger
--       blocking it while a report is open/under review (§15).
--  F18. SMALL HARDENING (NOT VALID, so old rows never block): an
--       offer message must carry an amount; order codes must match
--       the PM-ORD-XXXXXX shape the app generates; checkpoint
--       location/note keep the app's 120/280 caps (§16).
--
-- What this file does NOT change: pm_is_owner() and the owner email
-- (pulsemarketsupport@gmail.com — that spelling is used consistently
-- by the app, /admin and every migration; it is not changed), the fee
-- rules, the 48-hour rule, the return fault amounts, manual escrow,
-- the auth.uid() = null escape hatch, and the "only the two
-- participants can read a chat" rule.
--
-- Run AFTER milestones 3–15.

-- ---------------------------------------------------------------------------
-- 1) Wallet ledger reads: order participants (and the team) can read
--    the ledger rows of an order they are part of. The old "own rows
--    only" policy stays in place; this policy is additional (RLS
--    SELECT policies combine with OR). Without it the buyer and the
--    team read none of the seller's rows, so advanceAlreadyReleased()
--    in src/lib/orders.js always returns 0 for them and a release /
--    return after a shipping advance computes the wrong amounts and
--    is refused by the ledger trigger (F1).
-- ---------------------------------------------------------------------------
drop policy if exists "Order participants read ledger" on public.wallet_ledger;
create policy "Order participants read ledger"
  on public.wallet_ledger for select
  using (
    (auth.jwt() ->> 'email') = 'pulsemarketsupport@gmail.com'
    or exists (
      select 1 from public.orders o
      where o.id = wallet_ledger.order_id
        and (o.buyer_id = auth.uid() or o.seller_id = auth.uid())
    )
  );

-- ---------------------------------------------------------------------------
-- 2) Wallet ledger — Milestone 15's trigger, with fixes (F2,
--    F4, F10, F11, plus the refund-held / refund-available
--    owner-held exemptions) and coordinator additions (DB-1 actor
--    checks on release/refund/repayment/advance rows, DB-2 cash
--    orders never refund through the ledger). Everything else is
--    byte-for-byte Milestone 15, so the paired-leg checks, the fault
--    amounts, the debt/repayment/withdrawal rules and the held-sum
--    backstop behave exactly as before.
--    * (F4) The order row is locked (FOR UPDATE) before any sum is
--      read, so two money moves for the same order serialise instead
--      of both passing the held-sum / debt / balance check. A
--      withdrawal (usually order-less) takes an advisory lock keyed
--      by the user instead.
--    * (F11) A hold now requires the order to be 'paid'.
--    * (F10) A NULL courier no longer slips past the advance check.
--    * (F2) A team refund of a held order (refundHeldOrder, /admin:
--      the seller never shipped, no return is open) is allowed: the
--      held leg pays out exactly what is still held and the
--      available leg pays the buyer the item price + shipping, the
--      same amounts the app already sends.
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
        and not (public.pm_is_owner() and v_order.status = 'held') then
        raise exception 'A refund out of hold needs an open return, or a team refund of a held order.';
      end if;
    elsif NEW.bucket = 'available' then
      if public.pm_is_owner() and v_order.status = 'held'
        and coalesce(v_order.return_status, '') <> 'opened' then
        -- (F2) Team refund of a held order (refundHeldOrder): the
        -- buyer gets the item price + shipping back in full, the
        -- same amounts the app already sends. No return is open, so
        -- the fault-amount rules below do not apply.
        if NEW.user_id <> v_order.buyer_id
          or NEW.amount <> v_order.item_price + v_order.shipping_fee then
          raise exception 'A team refund of a held order pays the buyer the item price plus the shipping fee.';
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
    if NEW.bucket <> 'available' or NEW.amount <= 0 then
      raise exception 'A repayment is a positive available entry.';
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
-- 3) Paired legs, enforced at transaction end (F3). The row-level
--    checks in section 2 can only look BACKWARD: an available leg
--    needs its held leg, because the held leg was written first. They
--    can never see a mate that is never written — so a participant
--    could insert just the held leg of a release / refund / advance,
--    draining hold with no available credit, and the one-per-order
--    unique index would then refuse the real pair for ever. This
--    deferred constraint trigger runs at the END of the transaction,
--    when the whole pair is either there or not:
--      * a release or shipping_advance held leg needs its available
--        mate in the same order;
--      * a refund held leg needs its available mate, UNLESS the
--        order is reserved/paid/cancelled — cancelOrder() reverses a
--        hold with a single held leg by design, and the status
--        update is a separate call, so at commit time the order
--        still says reserved/paid (cancelled covers the same-
--        transaction case);
--      * a hold is a single leg by design, and debt / repayment /
--        withdrawal never have a held leg — none of them are
--        checked.
--    Why deferred, not a plain AFTER trigger: the app writes its
--    pairs in ONE statement, but auto_release_overdue_orders()
--    (Milestones 10/12) writes the two legs in TWO statements of
--    one transaction — a plain statement-level check would refuse
--    its first statement and break the server-side auto-release. A
--    deferred check sees both legs at commit time. The auth.uid()
--    bypass keeps the SQL Editor / pg_cron path working exactly as
--    Milestones 14/15 intended.
-- ---------------------------------------------------------------------------
create or replace function public.pm_check_ledger_pair()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if auth.uid() is null then
    return null;
  end if;
  if NEW.order_id is null then
    return null;
  end if;
  if NEW.kind not in ('release', 'shipping_advance', 'refund') then
    return null;
  end if;
  if NEW.bucket <> 'held' then
    return null;
  end if;
  if NEW.kind = 'refund' then
    select * into v_order from public.orders where id = NEW.order_id;
    if found and v_order.status in ('reserved', 'paid', 'cancelled') then
      -- Hold reversal on cancel: a single held leg, by design.
      return null;
    end if;
  end if;
  if not exists (
    select 1 from public.wallet_ledger
    where order_id = NEW.order_id
      and kind = NEW.kind
      and bucket = 'available'
  ) then
    raise exception 'A % move needs its matching available leg — the held leg alone cannot be written.', NEW.kind;
  end if;
  return null;
end;
$$;

drop trigger if exists pm_ledger_pair_check_trg on public.wallet_ledger;
create constraint trigger pm_ledger_pair_check_trg
  after insert on public.wallet_ledger
  deferrable initially deferred
  for each row execute function public.pm_check_ledger_pair();

-- ---------------------------------------------------------------------------
-- 4) Orders — update validation. Milestone 15's function, with
--    two changes: (F2) the team may move a held order to 'refunded',
--    and (DB-15) a return cannot be opened or changed while the
--    order is frozen.
--    refundHeldOrder() (src/lib/orders.js, /admin) refunds an order
--    the seller never shipped: it writes the refund pair first and
--    then closes the order out, and Milestone 15 refused it twice
--    (no held -> refunded move here, and the ledger refused the
--    refund legs without an open return — see section 2). The (b)
--    check below already requires both refund legs to exist before
--    ANY move to 'refunded', so this new move cannot mark money
--    refunded that never moved. Everything else is byte-for-byte
--    Milestone 15.
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
-- 5) Orders — insert validation. Milestone 15's function, with
--    additions (F8, DB-5, A c6). Everything else is byte-for-byte
--    Milestone 15.
--    * The delivery method must be one the listing actually offers
--      (Milestone 13 says delivery_methods is exactly ['meetup'] or
--      ['shipping']; a legacy empty array skips the check). The app
--      already refuses the other method in createOrder(); a direct
--      API call could order shipping on a meetup-only listing.
--    * A same_state listing may only ship inside the seller's state.
--      The app refuses the other half of this rule too (a meetup
--      for an out-of-state buyer), but the buyer's university state
--      is not stored on the order, so the database cannot check it.
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
  ) then
    raise exception 'Only verified students can place an order.';
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
  if NEW.item_price <> v_listing.price then
    raise exception 'The order price must match the listing price.';
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
  end if;

  return NEW;
end;
$$;

drop trigger if exists pm_validate_order_insert_trg on public.orders;
create trigger pm_validate_order_insert_trg
  before insert on public.orders
  for each row execute function public.pm_validate_order_insert();

-- ---------------------------------------------------------------------------
-- 6) Listing updates: Milestone 15's function, with the boost fix
--    (F6) and the open-order edit freeze (DB-13). Everything else
--    is byte-for-byte Milestone 15.
--    * A boost needs BOTH a tier and an expiry: setting
--      boosted_until alone used to count as a live boost
--      (isBoosted() in src/lib/listings.js only looks at
--      boosted_until), so a seller could grant themselves a free
--      boost with a direct API call. Clearing both is still fine.
--    * The expiry must match the tier: ₦500 buys 24 hours, ₦1,000
--      buys 72 hours. The +1h tolerance covers phone/server clock
--      skew (boostListing() computes the expiry from the phone's
--      clock). The old 72h absolute cap stays as well.
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
  return NEW;
end;
$$;

drop trigger if exists pm_validate_listing_update_trg on public.listings;
create trigger pm_validate_listing_update_trg
  before update on public.listings
  for each row execute function public.pm_validate_listing_update();

-- ---------------------------------------------------------------------------
-- 7) Listing deletes (F12). Deleting a listing cascades in the
--    database: every order for it (and their handoff codes,
--    checkpoints, evidence, chats, ratings and disputes) is deleted
--    too, while the wallet_ledger rows survive with their order link
--    nulled. The app already refuses this — deleteListing() in
--    src/lib/listings.js only deletes a listing whose orders were
--    all cancelled — but a direct API call could wipe a live order.
--    This trigger enforces the app's exact rule in the database: a
--    listing with any non-cancelled order cannot be deleted at all.
--    (The team can still remove one by hand from the SQL Editor,
--    where auth.uid() is null and the trigger steps aside.)
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_listing_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return OLD;
  end if;
  if exists (
    select 1 from public.orders o
    where o.listing_id = OLD.id
      and o.status <> 'cancelled'
  ) then
    raise exception 'This listing has orders on it — mark it sold instead of deleting it, so the order history stays.';
  end if;
  return OLD;
end;
$$;

drop trigger if exists pm_validate_listing_delete_trg on public.listings;
create trigger pm_validate_listing_delete_trg
  before delete on public.listings
  for each row execute function public.pm_validate_listing_delete();

-- ---------------------------------------------------------------------------
-- 8) Verification identity lock: Milestone 15's function, plus the
--    student email (F14) and the invite-code backfill exception
--    (DB-9). university, student_id, invite_code and now
--    student_email are immutable after submit — the app never updates
--    any of them afterwards (saveVerificationRow() only ever updates
--    referred_by on an existing row), and Settings only updates
--    chat_verified_only, which this trigger still allows.
-- ---------------------------------------------------------------------------
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
-- 9) Unboxing gate: the video must be the BUYER's (F9). Milestone
--    14's pm_has_verified_unboxing() accepted a verified unboxing
--    video from either participant, so the seller could film an
--    "unboxing" of their own item and certify their own delivery.
--    Only the buyer ever legitimately records an unboxing (the
--    tracking page tells the buyer to record it before delivery
--    confirms). The missing-table fail-open is unchanged.
-- ---------------------------------------------------------------------------
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
    select 1 from public.evidence e
    join public.orders o on o.id = e.order_id
    where e.order_id = p_order_id
      and e.kind = 'unboxing'
      and e.media_type = 'video'
      and e.verified = true
      and e.user_id = o.buyer_id
  ) into v_ok;
  return coalesce(v_ok, false);
exception when undefined_table then
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
-- 10) Dispute reports (F7). fileDispute() in src/lib/disputes.js
--     requires a verified dispute video (10–20s, recorded in the
--     app) before it files a report — but the database checked
--     nothing on disputes inserts, so a direct API call could file a
--     report and freeze the money with no proof at all. This trigger
--     enforces fileDispute's own checks in the database: the report
--     starts 'open', the category is one of the app's list, the
--     explanation is 20–2,000 characters, the contact email looks
--     like an email, and a verified dispute video for the order
--     already exists. (Who may file — only the order's buyer, as
--     themselves — is already enforced by the Milestone 12 RLS
--     policy, and stays there.)
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
-- 11) insert_notification: Milestone 15's function, with one change
--     (F13). The 120-per-hour rate limit read the count without
--     locking anything, so parallel RPC calls all read the same
--     count and all passed. The check is now serialised per caller
--     with an advisory lock (key 727002 is this function's own
--     namespace — the ledger withdrawal lock in section 2 uses
--     727001), so count-then-insert is accurate for each caller.
--     Everything else is byte-for-byte Milestone 15, including the
--     participant checks and the sender_id recording. (The RPC takes
--     p_order_id / p_conversation_id only to check who may be
--     notified — the notifications table has no such columns, so
--     nothing is dropped by not storing them.)
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
  -- (DB-7) Links stay inside the app: a stored https:// or
  -- protocol-relative link could send a student somewhere else.
  -- (The app already clamps links; this is the server backstop.)
  if p_link is not null and btrim(p_link) <> ''
    and (p_link not like '/%' or p_link like '//%') then
    raise exception 'notification links must stay inside the app';
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
  -- (F13) Serialise the count-then-insert per caller first, so
  -- parallel calls cannot all read the same count and all pass.
  -- The lock is transaction-scoped and released when this call
  -- commits or rolls back; different callers use different keys
  -- and never block each other.
  if auth.uid() is not null then
    perform pg_advisory_xact_lock(727002, hashtext(auth.uid()::text));
  end if;
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
-- 12) Handoff photo retakes (F5). Milestone 15 section E dropped
--     every UPDATE policy on storage.objects mentioning
--     evidence-media — including "Students replace their own
--     evidence media" (Milestone 7) — on the claim that the app
--     never updates a stored file. That is not true for handoff
--     photos: uploadHandoffPhoto() in src/lib/handoff.js uploads
--     with upsert:true to a FIXED path
--     (<user-id>/handoff-<orderId>-<role>.jpg), so retaking the
--     photo overwrites the same object and needs an UPDATE policy.
--     This restores exactly that, and nothing more: a student may
--     replace only files in their own folder whose name starts with
--     "handoff-". Verified evidence files
--     (<user-id>/evidence-<order>-<kind>-<timestamp>.*) stay
--     un-replaceable, which is what section E was protecting.
--     WARNING: do not re-run milestone-15.sql after this file — its
--     section E block would drop this policy again (see the header).
--     Residual: the policy cannot see whether that side has already
--     confirmed, so a same-path re-upload after confirming would
--     still swap the file behind the frozen URL on the order. The
--     order-column freeze (Milestone 15) still stops the URL itself
--     being swapped; fully closing the file swap needs the app to
--     use a timestamped handoff path instead of a fixed one.
-- ---------------------------------------------------------------------------
drop policy if exists "Students replace their own handoff photos" on storage.objects;
create policy "Students replace their own handoff photos"
  on storage.objects for update
  using (
    bucket_id = 'evidence-media'
    and (storage.foldername(name))[1] = auth.uid()::text
    and name like auth.uid()::text || '/handoff-%'
  )
  with check (
    bucket_id = 'evidence-media'
    and (storage.foldername(name))[1] = auth.uid()::text
    and name like auth.uid()::text || '/handoff-%'
  );

-- ---------------------------------------------------------------------------
-- 13) Shipping checkpoints (F15). addCheckpoint() in
--     src/lib/shipping.js only adds a checkpoint once the parcel
--     has shipped, but the database checked nothing — a direct API
--     call could add stops to an order that never shipped. The
--     seller-only RLS policy stays as it is; this trigger adds the
--     status gate (the team account is trusted past it, as in the
--     other triggers, and the SQL Editor bypass is unchanged).
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_checkpoint_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders%rowtype;
begin
  if auth.uid() is null or public.pm_is_owner() then
    return NEW;
  end if;
  select * into v_order from public.orders where id = NEW.order_id;
  if not found then
    raise exception 'That order does not exist.';
  end if;
  if v_order.status not in ('shipped', 'delivered') then
    raise exception 'Checkpoints start once the parcel has shipped.';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_validate_checkpoint_insert_trg on public.shipping_checkpoints;
create trigger pm_validate_checkpoint_insert_trg
  before insert on public.shipping_checkpoints
  for each row execute function public.pm_validate_checkpoint_insert();

-- ---------------------------------------------------------------------------
-- 14) Pickup ticket updates (F16). Milestone 15 validated pickup
--     inserts only (safe spot, real date today-to-90-days, HH:MM
--     time, not blocked). An update could move a pickup to a past
--     date or an invented spot afterwards. This trigger re-runs the
--     same checks whenever the spot, date or time changes (a
--     status-only change, e.g. scheduled -> done, passes straight
--     through). The blocked check is re-run too, matching the
--     insert rule.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_pickup_update()
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
-- 15) Dispute evidence cannot be deleted while the report is open
--     (F17). fileDispute() requires a verified dispute video before
--     filing, but the evidence DELETE policy lets the owner of a row
--     delete it at any time — including after filing, which leaves
--     the team with an open report and no proof. This blocks deleting
--     a dispute-kind row while an open or under-review report exists
--     for its order. Deleting before filing, or after the report is
--     resolved, still works, as does deleting any other kind.
-- ---------------------------------------------------------------------------
create or replace function public.pm_block_dispute_evidence_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return OLD;
  end if;
  if OLD.kind = 'dispute' and exists (
    select 1 from public.disputes
    where order_id = OLD.order_id
      and status in ('open', 'under_review')
  ) then
    raise exception 'This video is the evidence for an open report — it cannot be deleted until the report is resolved.';
  end if;
  return OLD;
end;
$$;

drop trigger if exists pm_block_dispute_evidence_delete_trg on public.evidence;
create trigger pm_block_dispute_evidence_delete_trg
  before delete on public.evidence
  for each row execute function public.pm_block_dispute_evidence_delete();

-- ---------------------------------------------------------------------------
-- 16) Small hardening (F18). All three constraints are NOT VALID, so
--     rows written before this file never block the migration, and
--     each is added in a DO block that ignores "already exists" (the
--     Milestone 14 pattern — Milestone 15's offer-cap block omits
--     the exception handler, so two simultaneous runs of that file
--     could error; this file does not repeat that).
--     * An offer message must carry an amount (sendOffer() in
--       src/lib/chat.js always sets one; a NULL amount could never
--       be accepted into an agreed price).
--     * Order codes must match the PM-ORD-XXXXXX shape
--       generateOrderCode() produces (the code is the bank-transfer
--       reference, so a free-text code would confuse the team).
--     * Checkpoint location/note keep the app's 120/280 caps.
-- ---------------------------------------------------------------------------
do $$
begin
  alter table public.messages
    add constraint messages_offer_needs_amount
    check (kind <> 'offer' or offer_amount is not null) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.orders
    add constraint orders_code_format
    check (code ~ '^PM-ORD-[A-Z0-9]{6}$') not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.shipping_checkpoints
    add constraint shipping_checkpoints_location_max_120
    check (location is null or char_length(location) <= 120) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.shipping_checkpoints
    add constraint shipping_checkpoints_note_max_280
    check (note is null or char_length(note) <= 280) not valid;
exception when duplicate_object then
  null;
end $$;

-- ---------------------------------------------------------------------------
-- 17) Offers always start pending (DB-6, coordinator addition).
--    Nothing forces offer_status='pending' on message INSERT, so a
--    buyer could insert their own offer already 'accepted' and then
--    set conversations.agreed_price to match (the M14 conversation
--    trigger allows it, because an accepted offer row with that
--    amount exists). Money never uses agreed_price — createOrder()
--    uses the listing price — so this is display / social-
--    engineering only, but it is still a lie the database should
--    not store. This trigger forces every new offer to 'pending'
--    before any other trigger sees it.
-- ---------------------------------------------------------------------------
create or replace function public.pm_force_offer_pending()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.kind = 'offer' then
    NEW.offer_status := 'pending';
  end if;
  return NEW;
end;
$$;

drop trigger if exists pm_force_offer_pending_trg on public.messages;
create trigger pm_force_offer_pending_trg
  before insert on public.messages
  for each row execute function public.pm_force_offer_pending();

-- ---------------------------------------------------------------------------
-- 18) Evidence rows must point at a real upload in your own folder
--    (DB-8, coordinator addition). Milestone 14 recomputes the
--    verified tick from the stored duration_seconds, but a direct
--    API insert could still claim any duration with any URL and earn
--    a verified tick — the database cannot measure a video file.
--    This does not fix that (see the report: trusted verification
--    needs server-side media inspection), but it forces at least a
--    real upload to the caller's own evidence-media folder, the
--    same pattern the handoff/waybill photo checks already use.
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
  return NEW;
end;
$$;

drop trigger if exists pm_evidence_url_check_trg on public.evidence;
create trigger pm_evidence_url_check_trg
  before insert on public.evidence
  for each row execute function public.pm_evidence_url_check();

-- ---------------------------------------------------------------------------
-- 19) One open dispute per order (DB-10, coordinator addition).
--    fileDispute() checks then inserts, so two parallel filings
--    could both pass and freeze the order twice — resolving one
--    then unfreezes it while the other is still open. The partial
--    unique index makes the second insert fail. Skipped with a
--    notice (not an error) if duplicate open reports already
--    exist — resolve those first, then re-run this block.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 20) Listing caps in the database (DB-11, coordinator addition).
--    The ₦10,000,000 price cap and the 120 / 2,000 character caps
--    were app-only until now; the database only checked price > 0
--    (Milestone 13). NOT VALID, like the Milestone 13 constraints,
--    so old rows never block the migration.
-- ---------------------------------------------------------------------------
do $$
begin
  alter table public.listings
    add constraint listings_price_max check (price <= 10000000) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.listings
    add constraint listings_title_max check (char_length(btrim(title)) <= 120) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.listings
    add constraint listings_description_max check (char_length(description) <= 2000) not valid;
exception when duplicate_object then
  null;
end $$;

-- ---------------------------------------------------------------------------
-- Done. Verify in the SQL Editor with a two-account test: checkout ->
-- pay -> hold -> ship (proof first, advance second) -> buyer release
-- (the release must now succeed with the advance already paid) ->
-- plus /admin refund of a held order that never shipped, a handoff
-- photo retake, and a wrong-code lock (5 parallel wrong guesses
-- still lock at 5). If the team ever needs a manual correction that
-- a trigger refuses, do it from the SQL Editor (no signed-in user
-- there, so the triggers step aside) — never by weakening these
-- rules. And do not re-run milestone-15.sql after this file (see the
-- header: its section E would drop the handoff-photo policy in
-- section 12).
-- ---------------------------------------------------------------------------
