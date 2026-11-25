-- PulseMarket Milestones 3 + 4 — server-side verification + real listings.
-- Run this ONCE in the Supabase dashboard: SQL Editor -> New query ->
-- paste this whole file -> Run. It creates the tables, the security rules
-- (RLS) and the photo storage bucket in one go. Safe to run twice: the
-- CREATE TABLE / policy statements use IF NOT EXISTS / DROP IF EXISTS, so
-- re-running it will not duplicate anything or delete existing rows.
--
-- No new environment variables are needed: the app already has
-- VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY in Vercel.

-- ---------------------------------------------------------------------------
-- 1) Student verification (Milestone 3)
-- One row per student. The app writes this when the student submits the
-- verification form, so the record follows them to any phone they sign in on.
-- ---------------------------------------------------------------------------
create table if not exists public.verifications (
  user_id uuid primary key references auth.users (id) on delete cascade,
  university text not null,
  student_id text not null,
  student_email text,
  invite_code text not null,
  status text not null default 'pending review',
  created_at timestamptz not null default now()
);

alter table public.verifications enable row level security;

drop policy if exists "Students read their own verification" on public.verifications;
create policy "Students read their own verification"
  on public.verifications for select
  using (auth.uid() = user_id);

drop policy if exists "Students write their own verification" on public.verifications;
create policy "Students write their own verification"
  on public.verifications for insert
  with check (auth.uid() = user_id);

drop policy if exists "Students update their own verification" on public.verifications;
create policy "Students update their own verification"
  on public.verifications for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 2) Real listings (Milestone 4)
-- Only real students post. There is NO sample or seed data in this file.
-- ships_to: 'same_state'  = meet in person / ship inside the seller's state
--          'nationwide'   = the seller ships anywhere in Nigeria
-- boost_tier: 500 (24h) or 1000 (72h). boosted_until is set when a boost is
-- bought; a listing counts as boosted only while boosted_until is in the
-- future. Boost payment is demo until real payments go live (Milestone 6).
-- seller_label: display name shown on the listing (the seller's account
-- handle, e.g. the part of their email before @). No real names are stored.
-- ---------------------------------------------------------------------------
create table if not exists public.listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users (id) on delete cascade,
  seller_label text not null default 'Student',
  title text not null,
  description text not null default '',
  price integer not null check (price >= 0),
  condition text not null,
  category text not null,
  university text not null,
  state text not null,
  ships_to text not null default 'same_state'
    check (ships_to in ('same_state', 'nationwide')),
  delivery_methods text[] not null default '{}',
  courier text,
  meetup_spot text,
  photos text[] not null default '{}',
  status text not null default 'active'
    check (status in ('active', 'reserved', 'sold')),
  boost_tier integer check (boost_tier in (500, 1000)),
  boosted_until timestamptz,
  views integer not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists listings_status_created_idx
  on public.listings (status, created_at desc);
create index if not exists listings_seller_idx
  on public.listings (seller_id);

alter table public.listings enable row level security;

-- Anyone (including visitors who are not signed in) can read ACTIVE
-- listings. A seller can also read their own reserved / sold listings.
drop policy if exists "Anyone reads active listings" on public.listings;
create policy "Anyone reads active listings"
  on public.listings for select
  using (status = 'active' or auth.uid() = seller_id);

-- Only a signed-in student can create a listing, and only as themselves.
drop policy if exists "Students create their own listings" on public.listings;
create policy "Students create their own listings"
  on public.listings for insert
  with check (auth.uid() = seller_id);

-- Only the seller can change or delete their own listing.
drop policy if exists "Sellers update their own listings" on public.listings;
create policy "Sellers update their own listings"
  on public.listings for update
  using (auth.uid() = seller_id)
  with check (auth.uid() = seller_id);

drop policy if exists "Sellers delete their own listings" on public.listings;
create policy "Sellers delete their own listings"
  on public.listings for delete
  using (auth.uid() = seller_id);

-- ---------------------------------------------------------------------------
-- 3) Watchlist (saved items)
-- ---------------------------------------------------------------------------
create table if not exists public.watchlist (
  user_id uuid not null references auth.users (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);

alter table public.watchlist enable row level security;

drop policy if exists "Students manage their own watchlist" on public.watchlist;
create policy "Students manage their own watchlist"
  on public.watchlist for all
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 4) Photo storage bucket: listing-photos (public read, owner-only write)
-- Photos are uploaded to <user-id>/<timestamp>-<n>.jpg inside the bucket.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('listing-photos', 'listing-photos', true)
on conflict (id) do nothing;

drop policy if exists "Anyone reads listing photos" on storage.objects;
create policy "Anyone reads listing photos"
  on storage.objects for select
  using (bucket_id = 'listing-photos');

drop policy if exists "Students upload their own listing photos" on storage.objects;
create policy "Students upload their own listing photos"
  on storage.objects for insert
  with check (
    bucket_id = 'listing-photos'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Students replace their own listing photos" on storage.objects;
create policy "Students replace their own listing photos"
  on storage.objects for update
  using (
    bucket_id = 'listing-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "Students delete their own listing photos" on storage.objects;
create policy "Students delete their own listing photos"
  on storage.objects for delete
  using (
    bucket_id = 'listing-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
