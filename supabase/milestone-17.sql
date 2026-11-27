-- PulseMarket Milestone 17 — VERIFICATION APPROVAL FLOW + FORBID HELD -> RELEASED.
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: every statement
-- below is idempotent (ADD COLUMN IF NOT EXISTS, INSERT ... ON
-- CONFLICT DO NOTHING, CREATE OR REPLACE, DROP IF EXISTS /
-- DROP TRIGGER IF EXISTS, CREATE POLICY after DROP POLICY IF EXISTS),
-- so re-running it changes nothing — including the grandfather
-- UPDATE in section 10, which only ever touches rows still sitting
-- at 'pending review'.
--
-- DEPLOY ORDER — READ THIS FIRST:
--   1. Push the Milestone 17 app code first (Verify.jsx ID-photo
--      upload, admin Pending verifications with Approve / Reject,
--      release only from delivered, resubmit UI).
--   2. Run this file ONLY AFTER supabase/milestone-16.sql is
--      confirmed live. Milestone 16 was confirmed live on
--      2026-11-25 ~18:58 WAT ("Success. No rows returned", code
--      pushed, live bundle verified on both Vercel links) — do not
--      run this file against a database where M16 has not run: the
--      patched functions below are Milestone 16's versions, and
--      running this file on a Milestone 15 database would silently
--      roll the M16 fixes back.
--   3. NEVER re-run milestone-15.sql after M16 (its section E would
--      drop the handoff-photo policy M16 section 12 restored), and
--      never re-run milestone-14/15/16.sql after this file: this
--      file REPLACES their verification gates and their held ->
--      released allowance, and re-running one of them would put the
--      old rules back.
--
-- WHAT THIS FILE DOES (owner-approved 2026-11-25, "as long as we
-- don't fail our customers" — no legit student locked out, no legit
-- order stranded):
--   * Verification means something now. A verifications row used to
--     be enough to post, chat and order — any email + any 2-char
--     student ID passed. From here on every gate requires
--     status = 'approved': listing insert (section 5), conversation
--     insert (section 6), order insert (section 7). A student whose
--     verification is still 'pending review' cannot post, start a
--     chat or place an order — the trigger error says so in plain
--     words, and the app tells them to wait for (or fix) their
--     review instead of failing silently.
--   * ID photos are collected and stored privately. Two new columns
--     (section 1) hold the front/back student-ID photo URLs, and a
--     PRIVATE 'verification-ids' bucket (section 2) holds the files:
--     only the student themself (own folder) and the team can read
--     them. They are never public.
--   * The team reviews, the student resubmits. review_verification()
--     (section 3) is team-only and sets 'approved' / 'rejected'.
--     resubmit_verification() (section 3) lets a REJECTED student —
--     and only a rejected student, only for their own row — send new
--     photos and go back to 'pending review'. Nobody can write
--     status directly: the update trigger (section 4) still refuses
--     every non-team status change except exactly this resubmit
--     path, which is recognised by a transaction flag the RPC sets
--     (the same pattern as the handoff flag).
--   * Nobody is locked out by the switch. The LAST statement
--     (section 10) grandfathers every existing 'pending review' row
--     to 'approved' — every student who is already in stays in with
--     no re-submit.
--   * Held money can no longer be released before delivery
--     (sections 8 + 9). held -> released is forbidden for EVERYONE,
--     including the team: release legs may only be written once the
--     order is 'delivered', and the order may only move to
--     'released' from 'delivered'. The exits that stay open:
--     held -> refunded by the team (seller never shipped, M16 admin
--     refund), delivered -> released (buyer / team / seller after
--     48h), and the 48h auto-release from delivered, which this file
--     does NOT touch (auto_release_overdue_orders() only ever
--     selects status = 'delivered' — verified in M10/M12).
--
-- WHAT THIS FILE DOES NOT CHANGE: pm_is_owner() and the owner
-- email (not referenced anywhere in this file — every team check
-- goes through public.pm_is_owner()), the fee rules, the 48-hour
-- rule, the return fault amounts, manual escrow, the identity lock
-- (university / student_id / student_email / invite_code immutable;
-- section 4 keeps M16 section 8 byte-for-byte apart from the
-- resubmit allowance), and the "only the two participants can read
-- a chat" rule.
--
-- THIS FILE HAS NOT BEEN EXECUTED ANYWHERE. There is no Postgres in
-- this VM, so it was verified by re-reading only: dollar-quote balance,
-- BEGIN/END and IF/END IF matching, every reproduced function
-- diffed line-by-line against milestone-14/15/16.sql (only the
-- documented changes differ), and every referenced table / column /
-- trigger name checked against the earlier milestones. Run it in
-- the SQL Editor and re-test: a pending-review student cannot post
-- or start a chat (plain error), a rejected student resubmits and
-- lands back at pending review, the team approves and the student
-- can post at once, a held order cannot release (buyer, seller or
-- team) but CAN be refunded by /admin, and a delivered order still
-- releases normally.
--
-- Run AFTER milestones 3–16.

-- ---------------------------------------------------------------------------
-- 1) ID photos on the verification row. The app uploads the front
--    and back of the student ID to the private 'verification-ids'
--    bucket (section 2) and saves the URLs here when the student
--    submits (new rows) or resubmits (rejected rows, via the RPC in
--    section 3 — never by writing status directly). The URLs alone
--    never change anything: only the team review and the resubmit
--    RPC move status, so a student swapping a URL by hand gains
--    nothing — the team reviews whatever is stored here.
-- ---------------------------------------------------------------------------
alter table public.verifications
  add column if not exists id_front_url text;
alter table public.verifications
  add column if not exists id_back_url text;

-- ---------------------------------------------------------------------------
-- 2) Private storage bucket: verification-ids (never public).
--    Files live under <user-id>/... inside the bucket, the same
--    folder convention as the listing-photos bucket in
--    supabase/milestone-3-4.sql. Policies mirror that bucket:
--    the student reads / uploads / replaces / deletes only their
--    own folder, and the team (public.pm_is_owner()) reads every
--    folder so Pending verifications can be reviewed. There is no
--    public-read policy on purpose — ID photos are never public.
--    UPDATE / DELETE for the owner's own files are kept (same as
--    listing-photos): a student fixing a blurry photo re-uploads to
--    their own folder, and the review gate is the status column,
--    not the file — swapping a file after approval changes no
--    status and earns nothing.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('verification-ids', 'verification-ids', false)
on conflict (id) do nothing;

drop policy if exists "Students read their own ID photos" on storage.objects;
create policy "Students read their own ID photos"
  on storage.objects for select
  using (
    bucket_id = 'verification-ids'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Team reads all ID photos" on storage.objects;
create policy "Team reads all ID photos"
  on storage.objects for select
  using (
    bucket_id = 'verification-ids'
    and public.pm_is_owner()
  );

drop policy if exists "Students upload their own ID photos" on storage.objects;
create policy "Students upload their own ID photos"
  on storage.objects for insert
  with check (
    bucket_id = 'verification-ids'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Students replace their own ID photos" on storage.objects;
create policy "Students replace their own ID photos"
  on storage.objects for update
  using (
    bucket_id = 'verification-ids'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'verification-ids'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Students delete their own ID photos" on storage.objects;
create policy "Students delete their own ID photos"
  on storage.objects for delete
  using (
    bucket_id = 'verification-ids'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- ---------------------------------------------------------------------------
-- 3) Review + resubmit RPCs. These are the ONLY ways status moves
--    in the app: the verifications UPDATE trigger (section 4)
--    refuses every direct status write by a student, so the app
--    never writes status itself.
--    * review_verification() — team only. Approves or rejects one
--      student's verification. The update trigger steps aside for
--      the team, so no flag is needed here.
--    * resubmit_verification() — a REJECTED student only, own row
--      only. New front/back photo URLs go back to 'pending review'
--      with the photos attached for the next review. It sets the
--      transaction flag 'pulsemarket.verification_resubmit' (same
--      pattern as the handoff flag) so the update trigger lets
--      exactly this one move through — rejected -> 'pending review'
--      with new photos, nothing else.
--    The photo URLs must point at files this student uploaded to
--    their own folder in the verification-ids bucket. The check
--    matches the bucket + own folder in any URL form (a private
--    bucket has no single public URL shape), the same folder rule
--    the handoff / waybill photo checks use.
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
  if p_front_url not like '%verification-ids/' || auth.uid()::text || '/%'
    or p_back_url not like '%verification-ids/' || auth.uid()::text || '/%' then
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
-- 4) Verification updates: Milestone 16 section 8's function, with
--    ONE change — the resubmit allowance. Everything else is
--    byte-for-byte Milestone 16: the team / SQL Editor bypass, the
--    status lock, the flagged lock, and the identity lock
--    (university / student_id / student_email / invite_code /
--    referred_by). The resubmit branch only runs when
--    resubmit_verification() set the transaction flag, and it only
--    lets exactly rejected -> 'pending review' with new ID photos
--    through. A student writing status directly still gets refused,
--    exactly as before.
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
      or NEW.chat_verified_only is distinct from OLD.chat_verified_only then
      raise exception 'A resubmission can only update the ID photos.';
    end if;
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
-- 5) Listing inserts: Milestone 14's function, with ONE change —
--    the gate now requires status = 'approved', not just a row.
--    Everything else is byte-for-byte Milestone 14. A student whose
--    verification is still 'pending review' (or rejected) gets a
--    plain error telling them approval comes first.
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
  return NEW;
end;
$$;

drop trigger if exists pm_validate_listing_insert_trg on public.listings;
create trigger pm_validate_listing_insert_trg
  before insert on public.listings
  for each row execute function public.pm_validate_listing_insert();

-- ---------------------------------------------------------------------------
-- 6) Conversation inserts: Milestone 15's function, with TWO
--    changes — both sides must now be status = 'approved' (the old
--    function never checked verification at all, only the flagged
--    flag, so a pending-review student could start chats), and the
--    team account is trusted past the gate, like the other
--    triggers. Everything else is byte-for-byte Milestone 15: the
--    flagged check (either side under review — no new chats) and the
--    blocked check. Existing conversations are untouched — this
--    trigger only fires on INSERT, so an open deal can still be
--    finished in its old chat.
-- ---------------------------------------------------------------------------
create or replace function public.pm_validate_conversation_insert()
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
-- 7) Order inserts: Milestone 16 section 5's function, with ONE
--    change — the buyer gate (DB-5) now requires status =
--    'approved', not just a row. Everything else is byte-for-byte
--    Milestone 16, including the flagged-buyer refusal. (The
--    seller of the order is already approved by section 5 — they
--    could not have posted the listing otherwise.)
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
-- 8) Order updates: Milestone 16 section 4's function, with ONE
--    change — the held -> released branch is GONE (it used to let
--    the buyer or the team release money before delivery), and an
--    explicit refusal now says why. Everything else is byte-for-byte
--    Milestone 16: held -> refunded stays team-only (the admin
--    refund of an order the seller never shipped), delivered ->
--    released stays buyer / team / seller-after-48h, the handoff
--    and unboxing gates still apply to delivered and to released,
--    and the (b) check still requires the release legs to exist
--    before ANY move to 'released'.
--    NOTE on the older files: Milestone 14 and Milestone 15 carried
--    the same held -> released branch, but Milestone 16's function
--    already replaced theirs — replacing Milestone 16's version
--    here supersedes all three at once. No other function moves an
--    order to 'released': auto_release_overdue_orders() (M10/M12)
--    only selects status = 'delivered' and is NOT changed.
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
    elsif OLD.status = 'paid' and NEW.status = 'held' and v_owner and OLD.payment_method = 'held' then
      null;
    elsif OLD.status = 'paid' and NEW.status = 'cancelled' and v_is_buyer then
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
-- 9) Wallet ledger: Milestone 16 section 2's function, with ONE
--    change — a release pair may now only be written once the order
--    is 'delivered'. The old gates let release legs be written
--    while the order was still 'held', which would have moved the
--    money to the seller before delivery even though the order
--    status could no longer follow (section 8). Two gates changed,
--    both in the 'release' branch: the held leg and the full-release
--    available leg. Everything else is byte-for-byte Milestone 16,
--    including the buyer-fault return leg — that one still pays the
--    seller the remaining shipping while the order is 'shipped' or
--    'delivered' with a return open, which is a return resolution,
--    not a release from hold, so its own gate is untouched. The
--    48h auto-release is untouched too: it runs with auth.uid()
--    null, so this trigger steps aside for it exactly as before.
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
-- 10) GRANDFATHER — RAN ONCE, 2026-11-25. DO NOT RUN AGAIN.
--     Every student who was already in stayed in: all existing
--     'pending review' rows became 'approved' on that one run.
--     The old header claimed a second run "updates zero rows" —
--     that is FALSE: any student who signed up and went pending
--     AFTER the first run would be mass-approved here with no ID
--     review. The statement below is commented out on purpose.
--     New students are reviewed from 'pending review' through
--     review_verification() only. (In the SQL Editor auth.uid()
--     is null, so the update trigger in section 4 steps aside for
--     this statement — that is why the original was dangerous.)
-- ---------------------------------------------------------------------------
-- update public.verifications set status = 'approved' where status = 'pending review';
-- ^^^ DISABLED — see above. Never uncomment this line.
