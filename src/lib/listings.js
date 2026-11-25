// Milestones 3 + 4 — Supabase data layer for verification, listings,
// watchlist and boost. Every function returns null / [] and logs the error
// when the tables do not exist yet (owner has not run the SQL), so the app
// shows an honest "not switched on yet" message instead of crashing.
import { supabase } from "./supabase";
import { OWNER_EMAIL } from "./payments";
import {
  CATEGORIES,
  CONDITIONS,
  SAFE_MEETUP_SPOTS,
  UNIVERSITY_NAMES,
  universityState,
} from "./data";

export const LISTING_PHOTOS_BUCKET = "listing-photos";

// Milestone 17 — student ID photos live in this PRIVATE bucket, never
// in a public one. The values stored in verifications.id_front_url /
// id_back_url are the storage PATHS (e.g. "<uid>/front-....jpg"), not
// public URLs: a private bucket has no working public URL, and the
// team opens the photos with a signed URL made from the path
// (verificationIdPhotoUrl below).
export const VERIFICATION_IDS_BUCKET = "verification-ids";

// Largest ID photo the app will upload (MB). The Verify form checks
// this when the photo is picked too; the upload checks again so a
// crafted call cannot skip it.
export const MAX_VERIFICATION_PHOTO_MB = 10;

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
    // Storage paths in the private verification-ids bucket (see
    // VERIFICATION_IDS_BUCKET above), or null when no photos are on
    // file — e.g. a student who verified before Milestone 17.
    idFrontUrl: data.id_front_url || null,
    idBackUrl: data.id_back_url || null,
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
  // student id, status and invite code are never overwritten from the
  // app afterwards — not even by a re-save carrying different values.
  // Only a missing referred_by may still be filled in. (Milestone 15
  // rule, kept for Milestone 17: a re-save must never overwrite an
  // approved row. A rejected student re-submits through the
  // resubmit_verification RPC, not through this function.)
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
  // Milestone 17: the two ID photo paths go on the row too, so the
  // team can open them when they review the student. They are storage
  // paths in the private verification-ids bucket, never public URLs.
  const { error } = await supabase.from("verifications").upsert({
    user_id: userId,
    university: rec.university,
    student_id: rec.studentId,
    student_email: rec.studentEmail || null,
    invite_code: rec.inviteCode,
    status: "pending review",
    id_front_url: rec.idFrontUrl || null,
    id_back_url: rec.idBackUrl || null,
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
// Verification approval flow (Milestone 17)
// ---------------------------------------------------------------------------
//
// A student is verified only when verifications.status is 'approved'.
// Anything else — 'pending review', 'rejected', or no row at all —
// is not verified, and the app gates on that everywhere (App.jsx,
// createListingRow below, chat.js startConversation). Students who
// verified before this flow existed were grandfathered to 'approved'
// by milestone-17.sql, so they are unaffected.
//
// The ID photos live in the PRIVATE verification-ids bucket at
// <user-id>/front-<timestamp>.jpg and <user-id>/back-<timestamp>.jpg.
// The bucket is private, so the app never builds a public URL for
// them: the team opens them with a short-lived signed URL
// (verificationIdPhotoUrl). The paths are what saveVerificationRow
// and resubmit_verification store in id_front_url / id_back_url.

// Team-only helpers check the signed-in email first (same pattern as
// disputes.js requireOwner) so a non-owner never even sends the query;
// the database (RLS + SECURITY DEFINER RPCs in milestone-17.sql)
// enforces it again server-side.
async function requireOwner() {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data, error } = await supabase.auth.getUser();
  if (error || !data?.user || data.user.email !== OWNER_EMAIL) {
    throw new Error("This page is not available.");
  }
  return data.user;
}

// Uploads both ID photos to the private verification-ids bucket and
// returns { frontPath, backPath } — the storage paths to store on the
// verification row. Mirrors the evidence.js upload pattern: the file
// must be a photo under the size limit, and if the second upload
// fails the first file is removed again so a failed submit leaves no
// orphan behind. Throws a plain Error; the caller must NOT save a
// verification row claiming photos exist when this throws.
export async function uploadVerificationIdPhotos(userId, frontFile, backFile) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!userId) throw new Error("Sign in first to upload your ID photos.");
  if (!frontFile || !backFile) {
    throw new Error("Add a photo of the front and back of your student ID.");
  }
  for (const [file, side] of [
    [frontFile, "front"],
    [backFile, "back"],
  ]) {
    if (file.type && !file.type.startsWith("image/")) {
      throw new Error(
        `The ${side} of your ID must be a photo — take a photo in the app.`
      );
    }
    if (file.size > MAX_VERIFICATION_PHOTO_MB * 1024 * 1024) {
      throw new Error(
        `That photo is too big — keep ID photos under ${MAX_VERIFICATION_PHOTO_MB}MB.`
      );
    }
  }
  const stamp = Date.now();
  const frontPath = `${userId}/front-${stamp}.jpg`;
  const backPath = `${userId}/back-${stamp}.jpg`;
  const { error: frontError } = await supabase.storage
    .from(VERIFICATION_IDS_BUCKET)
    .upload(frontPath, frontFile, { contentType: "image/jpeg", upsert: false });
  if (frontError) throw frontError;
  const { error: backError } = await supabase.storage
    .from(VERIFICATION_IDS_BUCKET)
    .upload(backPath, backFile, { contentType: "image/jpeg", upsert: false });
  if (backError) {
    // Best effort: a failed submit must not leave an orphan photo
    // behind (same as uploadEvidence in evidence.js).
    await supabase.storage.from(VERIFICATION_IDS_BUCKET).remove([frontPath]);
    throw backError;
  }
  return { frontPath, backPath };
}

// Best-effort removal of ID photos, e.g. when the re-submit RPC
// fails after the new photos were already uploaded. Never throws.
export async function removeVerificationIdPhotos(paths) {
  if (!supabase) return;
  const clean = (paths || []).filter(Boolean);
  if (clean.length === 0) return;
  await supabase.storage.from(VERIFICATION_IDS_BUCKET).remove(clean);
}

// Rejected student submits new ID photos: the SECURITY DEFINER RPC
// (milestone-17.sql) puts their row back to 'pending review' with
// the new photo paths. It — not the app — decides who may re-submit,
// so a student can never re-approve themselves this way.
export async function resubmitVerification(frontPath, backPath) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!frontPath || !backPath) {
    throw new Error("Add a photo of the front and back of your student ID.");
  }
  const { error } = await supabase.rpc("resubmit_verification", {
    p_front_url: frontPath,
    p_back_url: backPath,
  });
  if (error) throw error;
  return true;
}

// All verifications waiting for the team, oldest first so the
// longest-waiting student is reviewed first. Owner only.
export async function fetchPendingVerifications() {
  if (!supabase) return [];
  await requireOwner();
  const { data, error } = await supabase
    .from("verifications")
    .select(
      "user_id, university, student_id, student_email, status, id_front_url, id_back_url, created_at"
    )
    .eq("status", "pending review")
    .order("created_at", { ascending: true });
  if (error) throw error;
  return data || [];
}

// Team decision on one student. The SECURITY DEFINER RPC
// (milestone-17.sql) is the only thing that may change a status —
// the app never updates verifications.status directly.
export async function reviewVerification(userId, status) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!userId) throw new Error("Missing student.");
  if (status !== "approved" && status !== "rejected") {
    throw new Error("Choose approve or reject.");
  }
  await requireOwner();
  const { error } = await supabase.rpc("review_verification", {
    p_user_id: userId,
    p_status: status,
  });
  if (error) throw error;
  return true;
}

// Signed URL for one ID photo in the private bucket. The link works
// for `expiresInSeconds` (default 1 hour) and then stops working —
// the photo is never public. Returns null when there is no photo.
export async function verificationIdPhotoUrl(path, expiresInSeconds = 3600) {
  if (!supabase || !path) return null;
  const { data, error } = await supabase.storage
    .from(VERIFICATION_IDS_BUCKET)
    .createSignedUrl(path, expiresInSeconds);
  if (error) throw error;
  return data?.signedUrl || null;
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
  // A listing is only ever published by a student whose verification
  // is APPROVED on the server. The Sell page shows the form from the
  // device copy of the record, but that copy lives in localStorage
  // and anyone can write it — the server row is the check that
  // counts, and mere existence of a row is not enough: a student
  // still under review, or one who was rejected, must not sell.
  // Fail closed when the check itself fails: the insert would be the
  // next call, so a broken check must not let a listing through
  // unchecked.
  const { data: verification, error: verificationError } = await supabase
    .from("verifications")
    .select("user_id, status")
    .eq("user_id", row.seller_id)
    .maybeSingle();
  if (verificationError) {
    throw new Error("Could not check your verification — try again.");
  }
  if (!verification) {
    throw new Error("Only verified students can sell — finish verification first.");
  }
  if (verification.status === "rejected") {
    throw new Error(
      "Your verification was not approved — submit it again with clear ID photos to sell."
    );
  }
  if (verification.status !== "approved") {
    throw new Error(
      "Your verification is under review — you can sell once the team approves it."
    );
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
