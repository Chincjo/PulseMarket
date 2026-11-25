-- PulseMarket Milestone 13 — server-side listing completeness.
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: each constraint is
-- added inside a DO block that ignores "already exists", so re-running it
-- changes nothing.
--
-- Why this file exists: the Sell form now refuses to publish an incomplete
-- listing, but a form check alone can be bypassed (a crafted API call can
-- insert straight into the listings table). These CHECK constraints make
-- the DATABASE itself reject an incomplete listing, whatever calls it.
--
-- The constraints are added NOT VALID on purpose: listings posted before
-- this rule existed may have a short description or no photo, and a plain
-- ADD CONSTRAINT would fail the whole migration on those old rows. NOT
-- VALID still blocks every NEW incomplete listing and every update that
-- touches a constrained column. To enforce the rules on the old rows too,
-- clean them up first (give them a real description and photo, or delete
-- them), then run the VALIDATE CONSTRAINT lines at the bottom of this
-- file (they are commented out).
--
-- Columns used here come from supabase/milestone-3-4.sql — no column
-- names were guessed. delivery_methods is written by the app as exactly
-- ['meetup'] or ['shipping'], so the meetup/shipping checks key off that.

-- Helper: add a CHECK constraint only if it is not there yet.
-- (Postgres has no ADD CONSTRAINT IF NOT EXISTS, so the DO block below
-- catches the duplicate_object error instead.)

do $$
begin
  alter table public.listings
    add constraint listings_title_not_empty
    check (length(btrim(title)) > 0) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.listings
    add constraint listings_price_positive
    check (price > 0) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.listings
    add constraint listings_description_min_length
    check (length(btrim(description)) >= 20) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.listings
    add constraint listings_photos_required
    check (cardinality(photos) >= 1) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.listings
    add constraint listings_condition_not_empty
    check (length(btrim(condition)) > 0) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.listings
    add constraint listings_category_not_empty
    check (length(btrim(category)) > 0) not valid;
exception when duplicate_object then
  null;
end $$;

-- Delivery is always exactly one of these two (the app writes one or the
-- other, never both and never empty).
do $$
begin
  alter table public.listings
    add constraint listings_delivery_methods_valid
    check (
      delivery_methods = array['meetup']::text[]
      or delivery_methods = array['shipping']::text[]
    ) not valid;
exception when duplicate_object then
  null;
end $$;

-- Meet in person needs a safe meetup spot; shipping needs a courier.
do $$
begin
  alter table public.listings
    add constraint listings_meetup_spot_required
    check (
      delivery_methods <> array['meetup']::text[]
      or (meetup_spot is not null and length(btrim(meetup_spot)) > 0)
    ) not valid;
exception when duplicate_object then
  null;
end $$;

do $$
begin
  alter table public.listings
    add constraint listings_courier_required
    check (
      delivery_methods <> array['shipping']::text[]
      or (courier is not null and length(btrim(courier)) > 0)
    ) not valid;
exception when duplicate_object then
  null;
end $$;

-- ---------------------------------------------------------------------------
-- Optional second step — only after old incomplete listings are fixed or
-- deleted. Uncomment and run these to enforce the rules on every row,
-- including ones posted before Milestone 13.
-- ---------------------------------------------------------------------------
-- alter table public.listings validate constraint listings_title_not_empty;
-- alter table public.listings validate constraint listings_price_positive;
-- alter table public.listings validate constraint listings_description_min_length;
-- alter table public.listings validate constraint listings_photos_required;
-- alter table public.listings validate constraint listings_condition_not_empty;
-- alter table public.listings validate constraint listings_category_not_empty;
-- alter table public.listings validate constraint listings_delivery_methods_valid;
-- alter table public.listings validate constraint listings_meetup_spot_required;
-- alter table public.listings validate constraint listings_courier_required;
