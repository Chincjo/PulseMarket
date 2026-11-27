// Milestone 11 — Ratings after completed deals + invite codes.
// Every read function returns null / [] / 0-shaped data and logs the
// error when the tables do not exist yet (owner has not run
// supabase/milestone-11.sql), so the app says so honestly instead of
// crashing. Write functions throw a clear Error instead.
//
// Ratings: a buyer rates the seller once, only when the order status
// is 'released'. The database enforces it twice — a UNIQUE constraint
// on ratings.order_id and the RLS INSERT policy in milestone-11.sql —
// and this file checks the same rules up front so the buyer gets a
// plain-English error instead of a database error. Milestone 20
// (APP-7 / M-25): a 'delivered' CASH order can be rated too — cash
// ends at 'delivered', so cash buyers could never rate before. The
// database policy still requires 'released' until the Milestone 20
// SQL widens it, so a refused cash rating is caught below and shown
// as a plain "not switched on yet" message instead of a crash.
//
// Referrals: invite codes look like PM-XXXXXX (same pattern as the
// seller handoff code in handoff.js — 6 uppercase letters/digits,
// no I, O, 0 or 1, so the code cannot be misread off a phone screen).
// getOrCreateInviteCode reads the student's verifications row; the
// Milestone 3 + 4 policy "Students update their own verification"
// lets the owner update their own row, so a missing code can be
// filled in from the app. fetchReferralCount calls the
// count_referrals database function (see milestone-11.sql): the
// verifications SELECT policy only lets a student read their own row,
// so a plain client-side count would always read 0.
import { supabase } from "./supabase";
import { fetchVerificationRow } from "./listings";
import { notifyUser } from "./notifications";

// Invite codes: 'PM-' + 6 uppercase letters/digits (no I, O, 0 or 1).
export function generateInviteCode() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = new Uint32Array(6);
  if (typeof crypto !== "undefined" && crypto.getRandomValues) {
    crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < 6; i++) bytes[i] = Math.floor(Math.random() * 0xffffffff);
  }
  let code = "PM-";
  for (let i = 0; i < 6; i++) {
    code += chars[bytes[i] % chars.length];
  }
  return code;
}

const MAX_COMMENT_LENGTH = 280;

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

async function currentUserId() {
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getUser();
  if (error) {
    dbError(error, "get current user");
    return null;
  }
  return data?.user?.id || null;
}

async function readOrder(id) {
  if (!supabase || !id) return null;
  const { data, error } = await supabase
    .from("orders")
    .select("*")
    .eq("id", id)
    .maybeSingle();
  if (error) return dbError(error, "fetch order for rating");
  return data;
}

// ---------------------------------------------------------------------------
// Ratings
// ---------------------------------------------------------------------------

// Buyer only, only when the order status is 'released' — or when it
// is a 'delivered' CASH order (Milestone 20, APP-7: cash ends at
// 'delivered', so cash buyers could never rate). 1–5 stars, one
// rating per order. Returns the inserted rating row.
export async function submitRating(orderId, { stars, comment } = {}) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!orderId) throw new Error("Missing order.");
  const rating = Number(stars);
  if (!Number.isInteger(rating) || rating < 1 || rating > 5) {
    throw new Error("Choose 1 to 5 stars.");
  }
  const text = String(comment || "").trim();
  if (text.length > MAX_COMMENT_LENGTH) {
    throw new Error(`Keep your comment under ${MAX_COMMENT_LENGTH} characters.`);
  }
  const userId = await currentUserId();
  if (!userId) throw new Error("Sign in first to rate this order.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.buyer_id !== userId) {
    throw new Error("Only the buyer can rate this order.");
  }
  const isCashDelivered =
    order.status === "delivered" && order.payment_method === "cash";
  if (order.status !== "released" && !isCashDelivered) {
    throw new Error(
      "You can rate this seller once the order is released — or once a cash order is delivered."
    );
  }
  const existing = await fetchMyRatingForOrder(orderId);
  if (existing) {
    throw new Error("You have already rated this order.");
  }
  const { data, error } = await supabase
    .from("ratings")
    .insert({
      order_id: order.id,
      rater_id: userId,
      rated_id: order.seller_id,
      listing_id: order.listing_id || null,
      stars: rating,
      comment: text || null,
    })
    .select()
    .single();
  if (error) {
    // Unique constraint on order_id — the buyer already rated it
    // (e.g. from another phone at the same time).
    if (error.code === "23505") {
      throw new Error("You have already rated this order.");
    }
    // Milestone 20 (APP-7): the old database policy still requires
    // 'released', so a cash-delivered rating is refused until the
    // Milestone 20 SQL widens it. Say so plainly instead of
    // showing a database error — nothing broke, nothing was saved.
    // Milestone 22: only a policy refusal (42501) means "not
    // switched on yet". Any other failure (network, a different
    // RLS rule) used to be reported the same way, hiding the real
    // cause — those now surface as themselves.
    if (isCashDelivered && error.code === "42501") {
      throw new Error(
        "Ratings for cash orders are not switched on yet — the team is turning it on in the next update. Your rating was not saved."
      );
    }
    throw error;
  }
  // Milestone 10: tell the seller they were rated.
  notifyUser(order.seller_id, {
    kind: "rating",
    title: "You got a rating",
    body: `The buyer of order ${order.code} rated you ${rating} star${rating === 1 ? "" : "s"}.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  return data;
}

// Average (rounded to 1 decimal) + count for a seller. { average: 0,
// count: 0 } when the seller has no ratings yet — "New seller · No
// ratings yet", not a fake score. Milestone 20 (APP-15): pages past
// 1000 rows instead of silently averaging only the first 1000 — a
// seller with more than 1000 ratings used to show a wrong average.
export async function fetchSellerRating(sellerId) {
  if (!supabase || !sellerId) return { average: 0, count: 0 };
  const PAGE = 1000;
  let rows = [];
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from("ratings")
      .select("stars")
      .eq("rated_id", sellerId)
      .range(from, from + PAGE - 1);
    if (error) {
      dbError(error, "fetch seller rating");
      return { average: 0, count: 0 };
    }
    rows = rows.concat(data || []);
    if (!data || data.length < PAGE) break;
  }
  if (rows.length === 0) return { average: 0, count: 0 };
  const sum = rows.reduce((total, r) => total + (r.stars || 0), 0);
  return {
    average: Math.round((sum / rows.length) * 10) / 10,
    count: rows.length,
  };
}

// All ratings for a seller, newest first. There is no public profile
// table, so the rater label is the handle the rater uses on their own
// listings (listings.seller_label); a rater who never listed shows as
// "Student". A label is never invented from an email or a user id.
export async function fetchRatingsForSeller(sellerId) {
  if (!supabase || !sellerId) return [];
  const { data, error } = await supabase
    .from("ratings")
    .select("*")
    .eq("rated_id", sellerId)
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) {
    dbError(error, "fetch ratings for seller");
    return [];
  }
  const rows = data || [];
  if (rows.length === 0) return [];
  const raterIds = [...new Set(rows.map((r) => r.rater_id).filter(Boolean))];
  const labels = {};
  if (raterIds.length > 0) {
    const { data: listings, error: listingsError } = await supabase
      .from("listings")
      .select("seller_id, seller_label")
      .in("seller_id", raterIds);
    if (listingsError) {
      dbError(listingsError, "fetch rater labels");
    } else {
      for (const listing of listings || []) {
        if (listing.seller_id && !labels[listing.seller_id]) {
          labels[listing.seller_id] = listing.seller_label || "Student";
        }
      }
    }
  }
  return rows.map((r) => ({
    id: r.id,
    orderId: r.order_id,
    raterId: r.rater_id,
    raterLabel: labels[r.rater_id] || "Student",
    stars: r.stars,
    comment: r.comment,
    createdAt: r.created_at,
  }));
}

// The signed-in buyer's rating for one order, or null when they have
// not rated it yet.
export async function fetchMyRatingForOrder(orderId) {
  if (!supabase || !orderId) return null;
  const userId = await currentUserId();
  if (!userId) return null;
  const { data, error } = await supabase
    .from("ratings")
    .select("*")
    .eq("order_id", orderId)
    .eq("rater_id", userId)
    .maybeSingle();
  if (error) {
    dbError(error, "fetch my rating for order");
    return null;
  }
  return data || null;
}

// ---------------------------------------------------------------------------
// Referrals / invite codes
// ---------------------------------------------------------------------------

// Returns the student's invite code, creating one when their
// verification row has none. Returns null when Supabase is not
// configured, when the student has no verification row yet (verify
// first — Verify.jsx creates the row), or when the update fails. A
// code collision (unique index) is rare; retry with a fresh code.
export async function getOrCreateInviteCode(userId) {
  if (!supabase || !userId) return null;
  const row = await fetchVerificationRow(userId);
  if (!row) return null;
  const existing = String(row.inviteCode || "").trim();
  if (existing) return existing;
  let lastError = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    const code = generateInviteCode();
    // Only claim the code while the row still has none: two tabs (or
    // devices) creating a code at once used to each generate one and
    // the last write won — the loser then showed a code that was not
    // on the row. With the null guard the first write wins; a caller
    // that lost the race re-reads the row and returns the code that
    // is actually on it.
    const { data, error } = await supabase
      .from("verifications")
      .update({ invite_code: code })
      .eq("user_id", userId)
      .is("invite_code", null)
      .select("user_id");
    if (!error && data && data.length > 0) return code;
    if (error && error.code !== "23505") {
      lastError = error;
      break;
    }
    lastError = error;
    const fresh = await fetchVerificationRow(userId);
    if (fresh?.inviteCode) return String(fresh.inviteCode).trim();
  }
  dbError(lastError, "create invite code");
  return null;
}

// How many students joined with this invite code (verifications rows
// whose referred_by equals the code). Returns null when the count
// cannot be determined — Supabase not configured, or the owner has
// not run supabase/milestone-11.sql yet (count_referrals lives there).
// Null means "unknown", never 0: showing 0 for a count that was never
// read would be a lie.
export async function fetchReferralCount(code) {
  if (!supabase || !code) return null;
  const { data, error } = await supabase.rpc("count_referrals", {
    p_code: code,
  });
  if (error) {
    dbError(error, "fetch referral count");
    return null;
  }
  return typeof data === "number" ? data : null;
}
