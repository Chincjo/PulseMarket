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
