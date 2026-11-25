// Milestones 3 + 4 — Supabase data layer for verification, listings,
// watchlist and boost. Every function returns null / [] and logs the error
// when the tables do not exist yet (owner has not run the SQL), so the app
// shows an honest "not switched on yet" message instead of crashing.
import { supabase } from "./supabase";

export const LISTING_PHOTOS_BUCKET = "listing-photos";

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
    .select("user_id, referred_by")
    .eq("user_id", userId)
    .maybeSingle();
  if (readError) {
    dbError(readError, "read verification before save");
    return false;
  }
  if (existing) {
    if (referredBy && !existing.referred_by) {
      const { error } = await supabase
        .from("verifications")
        .update({ referred_by: referredBy })
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
    .order("created_at", { ascending: false });
  if (error) {
    dbError(error, "fetch my listings");
    return [];
  }
  return data || [];
}

export async function createListingRow(row) {
  const { data, error } = await supabase
    .from("listings")
    .insert(row)
    .select()
    .single();
  if (error) throw error;
  return data;
}

export async function updateListing(id, patch) {
  const { data, error } = await supabase
    .from("listings")
    .update(patch)
    .eq("id", id)
    .select()
    .single();
  if (error) throw error;
  return data;
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
  return updateListing(id, {
    boost_tier: tier.amount,
    boosted_until: boostedUntil,
  });
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
    .eq("user_id", userId);
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
