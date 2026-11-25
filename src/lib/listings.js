// Milestones 3 + 4 — Supabase data layer for verification, listings,
// watchlist and boost. Every function returns null / [] and logs the error
// when the tables do not exist yet (owner has not run the SQL), so the app
// shows an honest "not switched on yet" message instead of crashing.
import { supabase } from "./supabase";
import {
  CATEGORIES,
  CONDITIONS,
  SAFE_MEETUP_SPOTS,
  UNIVERSITY_NAMES,
  universityState,
} from "./data";

export const LISTING_PHOTOS_BUCKET = "listing-photos";

// Highest listing price the app will publish or save (₦). The Sell
// form and the edit form cap at this amount, but updateListing() /
// createListingRow() are callable from anywhere — without the cap
// here a price of ₦999,999,999 sailed through (the database only
// checks price > 0).
export const MAX_LISTING_PRICE = 10000000;

// Canonical courier names — keep in sync with COURIERS in
// src/lib/shipping.js and the courier list in src/pages/Sell.jsx.
const LISTING_COURIERS = [
  "GIG Logistics",
  "GUO Transport",
  "Chowdeck Relay",
  "Peace Logistics",
  "ABC Transport",
  "DHL Domestic",
  "Bus Park Waybill",
];

async function currentUserId() {
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getUser();
  if (error) return null;
  return data?.user?.id || null;
}

// Validate the VALUES of listing fields present in `patch` and return
// a cleaned copy (price normalised to a whole number). Throws a plain
// Error on the first bad value. Identity fields (seller, university,
// state, views) are never in an allowed key set — see
// validateListingKeys — so they cannot reach this check at all.
function checkListingValues(patch) {
  const clean = { ...patch };
  if (clean.title !== undefined) {
    const t = String(clean.title || "").trim();
    if (!t || t.length > 120) {
      throw new Error("Keep the item name between 1 and 120 characters.");
    }
    clean.title = t;
  }
  if (clean.price !== undefined) {
    const n = Math.round(Number(clean.price));
    if (!Number.isFinite(n) || n < 1 || n > MAX_LISTING_PRICE) {
      throw new Error(
        `Price must be a whole number between ₦1 and ₦${MAX_LISTING_PRICE.toLocaleString("en-NG")}.`
      );
    }
    clean.price = n;
  }
  if (clean.condition !== undefined && !CONDITIONS.includes(clean.condition)) {
    throw new Error("Choose a condition from the list.");
  }
  if (clean.category !== undefined && !CATEGORIES.includes(clean.category)) {
    throw new Error("Choose a category from the list.");
  }
  if (clean.description !== undefined) {
    const d = String(clean.description || "").trim();
    if (d.length < 20 || d.length > 2000) {
      throw new Error("Describe the item in 20 to 2,000 characters.");
    }
    clean.description = d;
  }
  if (
    clean.ships_to !== undefined &&
    !["same_state", "nationwide"].includes(clean.ships_to)
  ) {
    throw new Error("Choose who can buy this: same state or anywhere in Nigeria.");
  }
  if (clean.delivery_methods !== undefined) {
    const m = clean.delivery_methods;
    if (
      !Array.isArray(m) ||
      m.length !== 1 ||
      (m[0] !== "meetup" && m[0] !== "shipping")
    ) {
      throw new Error("Choose how the buyer gets it: meet in person or shipping.");
    }
  }
  if (
    clean.courier !== undefined &&
    clean.courier !== null &&
    !LISTING_COURIERS.includes(clean.courier)
  ) {
    throw new Error("Choose a courier from the list.");
  }
  if (
    clean.meetup_spot !== undefined &&
    clean.meetup_spot !== null &&
    !SAFE_MEETUP_SPOTS.includes(clean.meetup_spot)
  ) {
    throw new Error("Choose a safe meetup spot from the list.");
  }
  if (clean.photos !== undefined) {
    const photos = clean.photos;
    if (
      !Array.isArray(photos) ||
      photos.length < 1 ||
      photos.length > 4 ||
      photos.some((p) => typeof p !== "string" || !p.trim())
    ) {
      throw new Error("A listing needs 1 to 4 photos.");
    }
  }
  if (clean.status !== undefined && !["active", "reserved", "sold"].includes(clean.status)) {
    throw new Error("A listing status can only be active, reserved or sold.");
  }
  return clean;
}

function validateListingKeys(patch, allowed) {
  for (const key of Object.keys(patch)) {
    if (!allowed.has(key)) {
      throw new Error(`That field cannot be changed on a listing.`);
    }
  }
}

// Boost tiers: ₦500 for 24 hours, ₦1,000 for 3 days (72 hours).
// Boost payment is DEMO until real payments go live (Milestone 6).
export const BOOST_TIERS = [
  { amount: 500, hours: 24, label: "₦500 · 24 hours" },
  { amount: 1000, hours: 72, label: "₦1,000 · 3 days" },
];

export function isBoosted(listing) {
  if (!listing?.boosted_until) return false;
  return new Date(listing.boosted_until).getTime() > Date.now();
}

// Boosted listings first, then newest first.
export function sortListings(list) {
  return [...list].sort((a, b) => {
    const ab = isBoosted(a) ? 1 : 0;
    const bb = isBoosted(b) ? 1 : 0;
    if (ab !== bb) return bb - ab;
    return new Date(b.created_at) - new Date(a.created_at);
  });
}

// A listing is visible to a buyer in `buyerState` when it is in their state
// (meet in person / same-state shipping) or the seller ships nationwide.
export function visibleTo(listing, buyerState) {
  if (!buyerState) return true;
  return listing.state === buyerState || listing.ships_to === "nationwide";
}

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

// ---------------------------------------------------------------------------
// Verification (Milestone 3)
// ---------------------------------------------------------------------------

export async function fetchVerificationRow(userId) {
  if (!supabase || !userId) return null;
  const { data, error } = await supabase
    .from("verifications")
    .select("*")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) return dbError(error, "fetch verification");
  if (!data) return null;
  return {
    userId: data.user_id,
    email: null,
    university: data.university,
    studentEmail: data.student_email,
    studentId: data.student_id,
    status: data.status,
    inviteCode: data.invite_code,
    submittedAt: data.created_at,
  };
}

export async function saveVerificationRow(userId, rec) {
  if (!supabase || !userId) return false;
  // A referral to your own invite code can never count — drop it
  // instead of saving a self-referral.
  const referredBy =
    rec.referredBy && rec.inviteCode && rec.referredBy === rec.inviteCode
      ? null
      : rec.referredBy;
  // A verification row is written once and then locked: university,
  // student id and invite code are never overwritten from the app
  // afterwards. Only a missing referred_by may still be filled in.
  const { data: existing, error: readError } = await supabase
    .from("verifications")
    .select("user_id, referred_by, invite_code")
    .eq("user_id", userId)
    .maybeSingle();
  if (readError) {
    dbError(readError, "read verification before save");
    return false;
  }
  if (existing) {
    // Your own invite code can never count as your referrer — check
    // against the code already on the row, not only the code in this
    // request: on a re-save the request may carry no invite code at
    // all, and the top-of-function check would be skipped while the
    // row's own code still matches the referral.
    const ownCode = existing.invite_code || rec.inviteCode || null;
    const cleanReferredBy =
      referredBy && ownCode && referredBy === ownCode ? null : referredBy;
    if (cleanReferredBy && !existing.referred_by) {
      const { error } = await supabase
        .from("verifications")
        .update({ referred_by: cleanReferredBy })
        .eq("user_id", userId);
      if (error) {
        dbError(error, "save referral code");
        return false;
      }
    }
    return true;
  }
  // Status is ALWAYS "pending review" from the app, whatever the local
  // record claims: a student must never be able to ask for — or
  // re-save their way into — any other status. Only the PulseMarket
  // team can change it (the database trigger refuses anything else,
  // this just stops the app from ever sending a privileged value).
  const { error } = await supabase.from("verifications").upsert({
    user_id: userId,
    university: rec.university,
    student_id: rec.studentId,
    student_email: rec.studentEmail || null,
    invite_code: rec.inviteCode,
    status: "pending review",
  });
  if (error) {
    dbError(error, "save verification");
    return false;
  }
  // Milestone 11: referral attribution, saved as a separate update so
  // a missing referred_by column (milestone-11.sql not run yet) can
  // never break the verification save itself.
  if (referredBy) {
    const { error: refError } = await supabase
      .from("verifications")
      .update({ referred_by: referredBy })
      .eq("user_id", userId);
    if (refError) dbError(refError, "save referral code");
  }
  return true;
}

// ---------------------------------------------------------------------------
// Listings (Milestone 4)
// ---------------------------------------------------------------------------

export async function fetchActiveListings(limit = 200) {
  if (!supabase) return [];
  const { data, error } = await supabase
    .from("listings")
    .select("*")
    .eq("status", "active")
    .order("created_at", { ascending: false })
    .limit(Math.max(1, Math.min(200, Number(limit) || 200)));
  if (error) {
    dbError(error, "fetch listings");
    return [];
  }
  return data || [];
}

// One query for many listings (e.g. Evidence Locker titles) —
// never one fetch per listing.
export async function fetchListingsByIds(ids) {
  const clean = [...new Set((ids || []).filter(Boolean))];
  if (!supabase || clean.length === 0) return [];
  const { data, error } = await supabase
    .from("listings")
    .select("id, title")
    .in("id", clean);
  if (error) {
    dbError(error, "fetch listings by ids");
    return [];
  }
  return data || [];
}

export async function fetchListing(id) {
  if (!supabase || !id) return null;
  const { data, error } = await supabase
    .from("listings")
    .select("*")
    .eq("id", id)
    .maybeSingle();
  if (error) return dbError(error, "fetch listing");
  return data;
}

export async function fetchMyListings(userId) {
  if (!supabase || !userId) return [];
  const { data, error } = await supabase
    .from("listings")
    .select("*")
    .eq("seller_id", userId)
    .order("created_at", { ascending: false })
    .limit(200); // A seller's own list is bounded like every other list fetch.
  if (error) {
    dbError(error, "fetch my listings");
    return [];
  }
  return data || [];
}

export async function createListingRow(row) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!row || !row.seller_id) throw new Error("Missing seller.");
  // A listing is only ever published by a student with a verification
  // record on the server. The Sell page shows the form from the
  // device copy of the record, but that copy lives in localStorage
  // and anyone can write it — the server row is the check that
  // counts. Fail closed when the check itself fails: the insert
  // would be the next call, so a broken check must not let a listing
  // through unchecked.
  const { data: verification, error: verificationError } = await supabase
    .from("verifications")
    .select("user_id")
    .eq("user_id", row.seller_id)
    .maybeSingle();
  if (verificationError) {
    throw new Error("Could not check your verification — try again.");
  }
  if (!verification) {
    throw new Error("Only verified students can sell — finish verification first.");
  }
  validateListingKeys(
    row,
    new Set([
      "seller_id",
      "seller_label",
      "title",
      "description",
      "price",
      "condition",
      "category",
      "university",
      "state",
      "ships_to",
      "delivery_methods",
      "courier",
      "meetup_spot",
      "photos",
      "status",
      // Fresh-copy fields only: duplicateListing() copies a listing
      // with its boost cleared and views reset. A NEW listing is
      // never born boosted or already viewed — those values must be
      // exactly the fresh ones, or the row is rejected.
      "boost_tier",
      "boosted_until",
      "views",
    ])
  );
  if (row.boost_tier !== undefined && row.boost_tier !== null) {
    throw new Error("A new listing cannot start boosted — boost it after it is live.");
  }
  if (row.boosted_until !== undefined && row.boosted_until !== null) {
    throw new Error("A new listing cannot start boosted — boost it after it is live.");
  }
  if (row.views !== undefined && row.views !== 0) {
    throw new Error("A new listing starts with 0 views.");
  }
  const clean = checkListingValues(row);
  // The whole form is compulsory — the same rules the Sell page and
  // the database CHECKs enforce. A crafted call used to publish
  // with a missing photo, a 2-character description, an unknown
  // university, or a state that does not match the university.
  for (const field of [
    "title",
    "price",
    "condition",
    "category",
    "description",
    "university",
    "state",
    "ships_to",
    "delivery_methods",
    "photos",
    "status",
  ]) {
    if (clean[field] === undefined || clean[field] === null || clean[field] === "") {
      throw new Error(`A listing needs a ${field}.`);
    }
  }
  if (!UNIVERSITY_NAMES.includes(clean.university)) {
    throw new Error("Choose your university from the list.");
  }
  if (universityState(clean.university) !== clean.state) {
    throw new Error("The state does not match that university.");
  }
  if (
    clean.delivery_methods[0] === "meetup" &&
    (clean.meetup_spot === undefined || clean.meetup_spot === null)
  ) {
    throw new Error("Choose a safe meetup spot.");
  }
  if (
    clean.delivery_methods[0] === "shipping" &&
    (clean.courier === undefined || clean.courier === null)
  ) {
    throw new Error("Choose a courier.");
  }
  const { data, error } = await supabase
    .from("listings")
    .insert(clean)
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function updateListing(id, patch, opts = {}) {
  if (!supabase || !id) throw new Error("Missing listing.");
  if (!patch || typeof patch !== "object" || Object.keys(patch).length === 0) {
    throw new Error("Nothing to update.");
  }
  // Boost fields are only ever set through boostListing() (which
  // computes the tier and the expiry itself). A direct call with a
  // boosted_until is how a free permanent boost used to be set.
  const allowed = new Set([
    "title",
    "price",
    "condition",
    "category",
    "description",
    "ships_to",
    "delivery_methods",
    "courier",
    "meetup_spot",
    "photos",
    "status",
  ]);
  if (opts.allowBoost) {
    allowed.add("boost_tier");
    allowed.add("boosted_until");
  }
  validateListingKeys(patch, allowed);
  const clean = checkListingValues(patch);
  if (clean.boost_tier !== undefined && ![500, 1000].includes(clean.boost_tier)) {
    throw new Error("Unknown boost tier.");
  }
  if (clean.boosted_until !== undefined) {
    const until = new Date(clean.boosted_until).getTime();
    if (
      Number.isNaN(until) ||
      until <= Date.now() ||
      until > Date.now() + 72 * 60 * 60 * 1000
    ) {
      throw new Error("A boost can last at most 72 hours from now.");
    }
  }
  // A status-only patch is a system transition (an order was placed,
  // paid, delivered or cancelled) made by whichever side the order
  // flow runs as — the database trigger and the listing policies
  // still decide who may move it. Any other change is an edit, and
  // only the seller makes those: before this fix any caller could
  // rewrite another student's price, university or state, or set a
  // free boost, straight through this helper.
  const keys = Object.keys(clean);
  const isStatusOnly = keys.length === 1 && keys[0] === "status";
  if (!isStatusOnly) {
    const listing = await fetchListing(id);
    if (!listing) throw new Error("Listing not found.");
    const userId = await currentUserId();
    if (!userId || userId !== listing.seller_id) {
      throw new Error("Only the seller can edit this listing.");
    }
  }
  const { data, error } = await supabase
    .from("listings")
    .update(clean)
    .eq("id", id)
    .select()
    .single();
  if (error) throw error;
  return data;
}

// Put a listing back to 'active' — but never while an open order
// sits on it. The seller's "Back to active" button used to flip a
// reserved listing live even with a buyer mid-order: the listing
// then looked available while the one-open-order index refused the
// next buyer with a confusing "just reserved by someone else"
// error. Cancelling still flips the listing back (cancelOrder sets
// the order cancelled first, so no open order remains by then).
export async function reactivateListing(id) {
  if (!supabase || !id) throw new Error("Missing listing.");
  const { data: orders, error } = await supabase
    .from("orders")
    .select("id, status")
    .eq("listing_id", id)
    .limit(100);
  if (error) throw error;
  const open = (orders || []).filter((o) =>
    ["reserved", "paid", "held", "shipped", "delivered"].includes(o.status)
  );
  if (open.length > 0) {
    throw new Error(
      "This item has an open order on it — it stays reserved until that order is cancelled, delivered or refunded."
    );
  }
  return updateListing(id, { status: "active" });
}

export async function deleteListing(id) {
  if (!supabase || !id) throw new Error("Missing listing.");
  // Deleting a listing cascades in the database: every order for it
  // (and their handoff, checkpoints and evidence) is deleted too.
  // Refuse while any live order history exists — a seller with an
  // order on the listing marks it sold instead. Only a listing whose
  // orders were all cancelled may be deleted.
  const { data: orders, error: ordersError } = await supabase
    .from("orders")
    .select("id, status")
    .eq("listing_id", id)
    .limit(100);
  if (ordersError) throw ordersError;
  const blocking = (orders || []).filter((o) => o.status !== "cancelled");
  if (blocking.length > 0) {
    throw new Error(
      "This listing has orders on it — mark it sold instead of deleting it, so the order history stays."
    );
  }
  const { error } = await supabase.from("listings").delete().eq("id", id);
  if (error) throw error;
}

export async function duplicateListing(listing) {
  const copy = {
    seller_id: listing.seller_id,
    seller_label: listing.seller_label,
    title: `${listing.title} (copy)`,
    description: listing.description,
    price: listing.price,
    condition: listing.condition,
    category: listing.category,
    university: listing.university,
    state: listing.state,
    ships_to: listing.ships_to,
    delivery_methods: listing.delivery_methods,
    courier: listing.courier,
    meetup_spot: listing.meetup_spot,
    photos: listing.photos,
    status: "active",
    boost_tier: null,
    boosted_until: null,
    views: 0,
  };
  return createListingRow(copy);
}

export async function bumpViews(listing) {
  if (!supabase || !listing?.id) return;
  await supabase
    .from("listings")
    .update({ views: (listing.views || 0) + 1 })
    .eq("id", listing.id);
}

// Boost: records the tier and the expiry. No money moves yet — boost
// payment is demo until real payments go live (Milestone 6).
export async function boostListing(id, tierAmount) {
  const tier = BOOST_TIERS.find((t) => t.amount === tierAmount);
  if (!tier) throw new Error("Unknown boost tier.");
  const boostedUntil = new Date(
    Date.now() + tier.hours * 60 * 60 * 1000
  ).toISOString();
  return updateListing(
    id,
    {
      boost_tier: tier.amount,
      boosted_until: boostedUntil,
    },
    { allowBoost: true }
  );
}

// ---------------------------------------------------------------------------
// Listing photos — upload downscaled JPEGs to the listing-photos bucket.
// ---------------------------------------------------------------------------

async function dataUrlToBlob(dataUrl) {
  const res = await fetch(dataUrl);
  return res.blob();
}

export async function uploadListingPhotos(userId, dataUrls) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const urls = [];
  for (let i = 0; i < dataUrls.length; i++) {
    const blob = await dataUrlToBlob(dataUrls[i]);
    if (blob.size > 10 * 1024 * 1024) {
      throw new Error("That photo is too big — keep listing photos under 10MB.");
    }
    const path = `${userId}/${Date.now()}-${i}.jpg`;
    const { error } = await supabase.storage
      .from(LISTING_PHOTOS_BUCKET)
      .upload(path, blob, { contentType: "image/jpeg", upsert: false });
    if (error) throw error;
    const { data } = supabase.storage
      .from(LISTING_PHOTOS_BUCKET)
      .getPublicUrl(path);
    urls.push(data.publicUrl);
  }
  return urls;
}

// ---------------------------------------------------------------------------
// Watchlist (saved items)
// ---------------------------------------------------------------------------

export async function fetchWatchlistIds(userId) {
  if (!supabase || !userId) return [];
  const { data, error } = await supabase
    .from("watchlist")
    .select("listing_id")
    .eq("user_id", userId)
    .limit(500); // Bound: only used to test membership for one listing.
  if (error) {
    dbError(error, "fetch watchlist");
    return [];
  }
  return (data || []).map((r) => r.listing_id);
}

export async function setWatchlisted(userId, listingId, saved) {
  if (!supabase || !userId) return false;
  if (saved) {
    const { error } = await supabase
      .from("watchlist")
      .insert({ user_id: userId, listing_id: listingId });
    if (error) {
      // Already saved — a double tap, or the same save from another
      // device, hits the (user, listing) key. That is a success, not
      // an error: the item is on the watchlist either way.
      if (error.code === "23505") return true;
      dbError(error, "save to watchlist");
      return false;
    }
  } else {
    const { error } = await supabase
      .from("watchlist")
      .delete()
      .eq("user_id", userId)
      .eq("listing_id", listingId);
    if (error) {
      dbError(error, "remove from watchlist");
      return false;
    }
  }
  return true;
}
