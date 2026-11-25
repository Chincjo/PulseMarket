# Milestones 3 + 4 — what the owner must do in Supabase

Milestone 3 = student verification is saved on the server (not just on the
phone). Milestone 4 = real listings: students post real items, other students
see them, with boost and watchlist. **No sample or fake listings are created
anywhere — the app only ever shows what real students post.**

## Step 1 — Run the SQL (5 minutes, one time only)

1. Open [supabase.com](https://supabase.com) and sign in.
2. Open the **PulseMarket** project (the one whose URL is
   `https://jkvrkhqmzvpiovalhybf.supabase.co`).
3. On the left menu, click **SQL Editor**, then **New query**.
4. Open the file `supabase/milestone-3-4.sql` in this repo, copy the **whole**
   file, and paste it into the query box.
5. Click **Run** (bottom right). You should see "Success. No rows returned."
   If it shows an error, copy the error message and send it to Rio — do not
   guess at a fix.

That one run creates everything:

- Table `verifications` — one row per verified student.
- Table `listings` — real listings with price, condition, category,
  university, state, shipping reach, photos, status, boost and views.
- Table `watchlist` — items a student saved.
- Storage bucket `listing-photos` (public) for listing photos.
- Row Level Security on all three tables: anyone can read active listings,
  but only the seller can create, change or delete their own listing, and
  only the owner can read or change their own verification record.

Running the file a second time is safe — it will not duplicate anything or
delete existing rows.

## Step 2 — Nothing else to set up

- **No new environment variables.** The app already has
  `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in both Vercel projects,
  so the new tables work as soon as the SQL has run and the new code is
  deployed.
- **No keys or secrets in this file.** It only creates tables and rules.

## What happens before you run the SQL?

The app still works — accounts, sign-in and verification still work exactly
as before. But publishing a listing will show an honest message: "Publishing
is not switched on yet — the owner is setting up the listings database."
Once you run the SQL and the new code is live, publishing works immediately.

## What happens after you run the SQL?

- Students who already verified keep their verification (it is still saved
  on their phone as a backup). The next time they open the app, their
  verification is also saved to the server, so it follows them to any phone
  they sign in on.
- The first real listing appears on Home ("Near you" for students in the
  seller's state, "Just dropped" for everyone the seller ships to) and in
  Search as soon as a student publishes it. Until then, both sections show
  honest "nothing yet" messages — no fake listings, ever.
- Boost has two tiers: **₦500 for 24 hours** and **₦1,000 for 3 days**.
  Boosted listings get a "Boosted" label and rank first. Boost payment is
  **demo for now** — the app says so on the boost screen. Real boost
  payments come with Milestone 6 (Paystack), after Paystack activation.
