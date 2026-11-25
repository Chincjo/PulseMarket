-- PulseMarket Milestone 11 — Ratings + referrals.
--
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. Safe to run twice: the CREATE TABLE /
-- policy / index statements use IF NOT EXISTS / DROP IF EXISTS, so
-- re-running it will not duplicate anything or delete existing rows.
--
-- RUN AFTER the Milestone 3 + 4 migration (it creates
-- public.verifications, which the ALTER TABLE below extends) and after
-- Milestone 6 (it creates public.orders, which the ratings table and
-- its INSERT policy reference).
--
-- No new environment variables are needed.
--
-- ---------------------------------------------------------------------------
-- 1) Ratings — one rating per completed order, buyer rates seller
-- ---------------------------------------------------------------------------
-- A rating exists only after a real deal: the buyer rates the seller
-- once the order status is 'released'. There is NO sample or seed data
-- in this file. One rating per order is enforced by the UNIQUE
-- constraint on order_id (a second rating for the same order fails).
create table if not exists public.ratings (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders (id) on delete cascade,
  rater_id uuid not null references auth.users (id) on delete cascade,
  rated_id uuid not null references auth.users (id) on delete cascade,
  listing_id uuid references public.listings (id) on delete set null,
  stars integer not null check (stars >= 1 and stars <= 5),
  comment text,
  created_at timestamptz not null default now()
);

create index if not exists ratings_rated_idx
  on public.ratings (rated_id, created_at desc);
create index if not exists ratings_order_idx
  on public.ratings (order_id);

alter table public.ratings enable row level security;

-- Anyone signed in can read ratings — a seller's average and their
-- past ratings are public trust signals on listings and profiles.
drop policy if exists "Signed-in students read ratings" on public.ratings;
create policy "Signed-in students read ratings"
  on public.ratings for select
  using (auth.role() = 'authenticated');

-- Only the buyer of a released order can insert a rating for it, and
-- only for that order's seller. The subquery reads public.orders: the
-- Milestone 6 policy "Order participants read orders" lets the buyer
-- read their own order, so this check sees it. No UPDATE or DELETE
-- policy exists on purpose — a rating, once given, cannot be changed
-- or removed from the app.
drop policy if exists "Buyers rate their released orders" on public.ratings;
create policy "Buyers rate their released orders"
  on public.ratings for insert
  with check (
    auth.uid() = rater_id
    and exists (
      select 1
      from public.orders o
      where o.id = order_id
        and o.buyer_id = auth.uid()
        and o.seller_id = rated_id
        and o.status = 'released'
    )
  );

-- ---------------------------------------------------------------------------
-- 2) Referrals — invite codes on verifications
-- ---------------------------------------------------------------------------
-- invite_code already exists on verifications from Milestone 3 + 4
-- (text not null), so this ADD COLUMN is a no-op on a database where
-- that migration ran — it only helps a database where the column is
-- somehow missing. referred_by is new: it holds the invite code of
-- the student who referred this student (set at verification time by
-- the app; the coordinator wires that attribution into Verify.jsx).
alter table public.verifications
  add column if not exists invite_code text;
alter table public.verifications
  add column if not exists referred_by text;

-- Invite codes must be unique, but the codes handed out before this
-- migration were generated in the app with Math.random, so duplicates
-- are possible in old rows. Creating the unique index blindly would
-- fail the whole migration if a duplicate exists, so it is created
-- only when no code is used twice. If the index is skipped, the app
-- still retries with a fresh code on a collision (see
-- getOrCreateInviteCode in src/lib/ratings.js) — check the database
-- and fix any duplicate codes by hand before re-running this file.
do $$
begin
  if not exists (
    select 1
    from public.verifications
    group by invite_code
    having count(*) > 1
  ) then
    create unique index if not exists verifications_invite_code_unique_idx
      on public.verifications (invite_code);
  end if;
end $$;

-- Referral counts cannot be read from the app directly: the Milestone
-- 3 + 4 policy "Students read their own verification" lets a student
-- read only their own row, so counting other students' referred_by
-- values through the client would always return 0. This function
-- runs with the database's own rights and returns ONLY the count for
-- one code — it never exposes anyone's verification row. The app
-- calls it with supabase.rpc("count_referrals", { p_code: code }).
create or replace function public.count_referrals(p_code text)
returns integer
language sql
security definer
set search_path = public
as $$
  select count(*)::integer
  from public.verifications
  where referred_by = p_code;
$$;

revoke all on function public.count_referrals(text) from public;
grant execute on function public.count_referrals(text) to authenticated;
