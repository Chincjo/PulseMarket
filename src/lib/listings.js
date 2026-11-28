// Milestones 3 + 4 — Supabase data layer for verification, listings,
// watchlist and boost. Every function returns null / [] and logs the error
// when the tables do not exist yet (owner has not run the SQL), so the app
// shows an honest "not switched on yet" message instead of crashing.
import { supabase } from "./supabase";
import { OWNER_EMAIL } from "./payments";
import { assertRealPhoto, assertSellerClearOfDebt } from "./shipping";
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
export const MAX_LISTING_PRICE = 50000000;

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
  const { row } = await fetchVerificationRowChecked(userId);
  return row;
}

// Milestone 22: same read as fetchVerificationRow, but the caller can
// tell a failed read apart from "no row". That matters before a
// submit: a failed read used to look exactly like a first-time
// submitter, so an already-approved student could re-submit photos
// and end up "pending review" on the device while the team still saw
// the old row. Callers that only need the row keep using
// fetchVerificationRow above.
export async function fetchVerificationRowChecked(userId) {
  if (!supabase || !userId) return { row: null, failed: true };
  const { data, error } = await supabase
    .from("verifications")
    .select("*")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) {
    dbError(error, "fetch verification");
    return { row: null, failed: true };
  }
  if (!data) return { row: null, failed: false };
  return {
    row: {
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
      // Milestone 19: why the team rejected this student (fixed list)
      // and their optional short note — null unless rejected.
      rejectionReason: data.rejection_reason || null,
      rejectionNote: data.rejection_note || null,
    },
    failed: false,
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
    // The MIME check above is skipped when a file carries no type
    // at all, so a renamed document could sail through as an ID
    // photo. The magic-byte check catches it — same check as the
    // listing and waybill photos.
    await assertRealPhoto(file, `ID ${side}`);
  }
  // Milestone 20 (APP-12): the front and back photos must be two
  // different files — the same photo twice used to sail through
  // (the server RPC only compares the stored URLs, which are always
  // different paths). Same object, or byte-for-byte the same file,
  // is refused before anything is uploaded.
  if (frontFile === backFile) {
    throw new Error(
      "The front and back photos must be different files — add a photo of each side of your ID."
    );
  }
  if (
    frontFile.size === backFile.size &&
    typeof frontFile.arrayBuffer === "function" &&
    typeof backFile.arrayBuffer === "function"
  ) {
    const [frontBytes, backBytes] = await Promise.all([
      frontFile.arrayBuffer(),
      backFile.arrayBuffer(),
    ]);
    const a = new Uint8Array(frontBytes);
    const b = new Uint8Array(backBytes);
    let same = a.length === b.length;
    for (let i = 0; same && i < a.length; i++) {
      if (a[i] !== b[i]) same = false;
    }
    if (same) {
      throw new Error(
        "The front and back photos must be different files — add a photo of each side of your ID."
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

// Milestone 19 — the fixed list of rejection reasons. A rejection
// must carry one of these (the review_verification RPC refuses a
// reject without one); the free-text note is separate and optional.
export const VERIFICATION_REJECTION_REASONS = [
  "blurry",
  "wrong document",
  "name mismatch",
  "expired",
  "other",
];

// Milestone 19 (Decision 2) — a student whose verification is still
// 'pending review' replaces their own ID photos while waiting.
// Uploads FIRST, then calls the replace_verification_photos RPC;
// if the RPC fails, the new photos are removed again so no row
// change happens and nothing is left orphaned in the bucket —
// exactly the upload-then-RPC pattern resubmitVerification uses.
// Status stays 'pending review'; the row's updated_at moves, so
// the student goes to the back of the review queue (the team
// reviews the newest photos). Throws a plain Error on failure.
export async function replaceVerificationPhotos(userId, frontFile, backFile) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!userId) throw new Error("Sign in first to replace your ID photos.");
  let photoPaths;
  try {
    photoPaths = await uploadVerificationIdPhotos(userId, frontFile, backFile);
  } catch (err) {
    // Validation failures (too big, not a photo, magic-byte fail,
    // same file twice) are plain Errors thrown by the upload helper
    // — pass the real reason on, so the student knows what to fix.
    // A storage/network failure arrives as a Supabase error object,
    // not an Error, and gets the plain connection message instead.
    if (err instanceof Error) throw err;
    throw new Error("Your ID photos could not be uploaded. Please check your connection and try again.");
  }
  try {
    const { error } = await supabase.rpc("replace_verification_photos", {
      p_front_url: photoPaths.frontPath,
      p_back_url: photoPaths.backPath,
    });
    if (error) throw error;
  } catch (err) {
    await removeVerificationIdPhotos([photoPaths.frontPath, photoPaths.backPath]);
    throw new Error(
      err?.message ||
        "Could not replace your ID photos. Please check your connection and try again."
    );
  }
  return photoPaths;
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

// All verifications waiting for the team, longest-waiting first.
// Milestone 19: ordered by updated_at, not created_at — a student
// who replaces their photos while waiting (or resubmits after a
// rejection) gets a fresh updated_at, so they go to the back of the
// queue and the team reviews the newest photos. Falls back to the
// old created_at order when the Milestone 19 SQL has not run yet
// (no updated_at column), so the queue keeps working during the
// deploy window instead of erroring.
export async function fetchPendingVerifications() {
  if (!supabase) return [];
  await requireOwner();
  const selectCols =
    "user_id, university, student_id, student_email, status, id_front_url, id_back_url, created_at, updated_at, rejection_reason, rejection_note";
  const { data, error } = await supabase
    .from("verifications")
    .select(selectCols)
    .eq("status", "pending review")
    .order("updated_at", { ascending: true })
    .order("created_at", { ascending: true });
  if (!error) return data || [];
  if (/updated_at/i.test(error.message || "")) {
    const retry = await supabase
      .from("verifications")
      .select(
        "user_id, university, student_id, student_email, status, id_front_url, id_back_url, created_at"
      )
      .eq("status", "pending review")
      .order("created_at", { ascending: true });
    if (retry.error) throw retry.error;
    return retry.data || [];
  }
  throw error;
}

// Team decision on one student. The SECURITY DEFINER RPC
// (milestone-17.sql, extended in milestone-19) is the only thing
// that may change a status — the app never updates
// verifications.status directly.
// Milestone 19: rejecting NEEDS a reason from
// VERIFICATION_REJECTION_REASONS, plus an optional short note
// (280 characters max) for the student. Approving clears any
// earlier reason and note. The reason/note arguments are optional
// here only so an approval call stays a two-argument call; a
// reject without a reason is refused — by this helper and by the
// RPC — with a plain error.
export async function reviewVerification(userId, status, reason = null, note = null) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!userId) throw new Error("Missing student.");
  if (status !== "approved" && status !== "rejected") {
    throw new Error("Choose approve or reject.");
  }
  const cleanReason = reason == null ? null : String(reason).trim();
  const cleanNote = note == null ? null : String(note).trim();
  if (status === "rejected") {
    if (!VERIFICATION_REJECTION_REASONS.includes(cleanReason)) {
      throw new Error("Choose a reason for the rejection.");
    }
    if (cleanNote !== null && cleanNote.length > 280) {
      throw new Error("Keep the note to the student under 280 characters.");
    }
  }
  await requireOwner();
  const { error } = await supabase.rpc("review_verification", {
    p_user_id: userId,
    p_status: status,
    // An approval never carries a reason or a note — the RPC clears
    // any earlier ones, so send null either way.
    p_reason: status === "rejected" ? cleanReason : null,
    p_note: status === "rejected" ? cleanNote || null : null,
  });
  if (error) throw error;
  return true;
}

// Signed URL for one ID photo in the private bucket. Team only —
// the only caller is the /admin photo viewer. Storage RLS also
// refuses a non-team caller, but never mint a signed URL for a
// photo the caller was not allowed to ask for: a signed URL, once
// minted, is a bearer link that works for anyone who holds it
// until it expires. The link works for `expiresInSeconds`
// (default 1 hour) and then stops working — the photo is never
// public. Returns null when there is no photo.
export async function verificationIdPhotoUrl(path, expiresInSeconds = 3600) {
  if (!supabase || !path) return null;
  await requireOwner();
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

export async function fetchMyListings(userId, { before } = {}) {
  if (!supabase || !userId) return [];
  let query = supabase
    .from("listings")
    .select("*")
    .eq("seller_id", userId)
    .order("created_at", { ascending: false });
  if (before) query = query.lt("created_at", before);
  const { data, error } = await query.limit(200); // A seller's own list is bounded like every other list fetch.
  if (error) {
    dbError(error, "fetch my listings");
    return [];
  }
  const rows = data || [];
  // Cursor for the Dashboard "Load more": true when a full page came
  // back, so another page may exist.
  rows.hasMore = rows.length === 200;
  return rows;
}

export async function createListingRow(row) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!row || !row.seller_id) throw new Error("Missing seller.");
  // The row's seller must be the signed-in student. The function
  // used to check that seller's verification and then insert, so a
  // crafted call could publish a listing under another student's
  // name with only RLS in the way. (This file has no currentUser()
  // helper — this is the same supabase.auth.getUser() call
  // updateListing uses.)
  const { data: authData } = await supabase.auth.getUser();
  const caller = authData?.user || null;
  if (!caller || caller.id !== row.seller_id) {
    throw new Error("You can only post a listing as yourself.");
  }
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
    .select("user_id, university, status, flagged")
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
  // A flagged account (5 wrong handoff codes) is under team review:
  // no new listings until the team clears it — the same rule as
  // startConversation in chat.js, and the same as the buyer side
  // of the order rules. (The database listing trigger does not
  // check flagged yet — see the Milestone 18 notes — so the app
  // enforces it here and the trigger is the backstop to add.)
  if (verification.flagged) {
    throw new Error(
      "Your account is under review — contact support before posting a new listing."
    );
  }
  // Morning deep check 2026-11-28: the seller-debt gate was only
  // wired in Sell.jsx, so a crafted call to createListingRow — or
  // any other caller — could publish a listing while the seller
  // still owes money from an earlier order. The gate belongs here
  // (shipping.js exports it; listings.js already imports from
  // shipping.js, so no cycle).
  await assertSellerClearOfDebt(row.seller_id);
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
  // A new listing is always born 'active' — a passed-in status of
  // 'sold' or 'reserved' used to sail through validation and land
  // in the insert as-is.
  clean.status = "active";
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
  // Milestone 22: the university is locked at verification. A
  // UNIPORT-verified student used to be able to post as "University
  // of Lagos" — the listing then showed the wrong state, state
  // filtering and same-state rules broke, and the shipping zone was
  // priced from the spoofed state. The database trigger is the
  // backstop (milestone-22.sql); this refuses it in the app first.
  if (clean.university !== verification.university) {
    throw new Error(
      "A listing must use your verified university — you verified as a student of " +
        verification.university +
        "."
    );
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

// How many orders are still open on a listing (reserved, paid,
// held, shipped or delivered). Count, don't fetch: the old code
// fetched the first 100 orders, so a listing with more than 100
// orders could be put back to active while a live order sat past
// the first page.
export async function fetchOpenOrderCount(listingId) {
  if (!supabase || !listingId) return 0;
  const { count, error } = await supabase
    .from("orders")
    .select("id", { count: "exact", head: true })
    .eq("listing_id", listingId)
    .in("status", ["reserved", "paid", "held", "shipped", "delivered"]);
  if (error) throw error;
  return count || 0;
}

// Whether a non-seller participant may move a listing's status, for
// the status-only path in updateListing() (Milestone 22). The move
// must match the caller's own order on this listing: 'reserved'
// while their order is reserved/paid (placing the order), 'sold'
// once it is delivered/released (confirming delivery / releasing
// the money), and 'active' once it is cancelled/refunded — and
// only when no other open order sits on the listing, so a past
// buyer cannot free a listing while another buyer's order is open.
// A caller with no order on the listing may not move it at all.
async function statusMoveAllowedForParticipant(listingId, callerId, targetStatus) {
  if (!supabase || !listingId || !callerId) return false;
  const { data, error } = await supabase
    .from("orders")
    .select("id, status")
    .eq("listing_id", listingId)
    .eq("buyer_id", callerId);
  if (error) return false;
  const statuses = (data || []).map((o) => o.status);
  if (targetStatus === "reserved") {
    return statuses.some((s) => s === "reserved" || s === "paid");
  }
  if (targetStatus === "sold") {
    return statuses.some((s) => s === "delivered" || s === "released");
  }
  if (targetStatus === "active") {
    if (!statuses.some((s) => s === "cancelled" || s === "refunded")) return false;
    try {
      return (await fetchOpenOrderCount(listingId)) === 0;
    } catch {
      return false;
    }
  }
  return false;
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
  // only the seller — or the PulseMarket team, who fix listings by
  // hand — makes those: before this fix any caller could rewrite
  // another student's price, university or state, or set a free
  // boost, straight through this helper. (Milestone 20, APP-10:
  // the team account is now allowed too; order participants still
  // only move the status through the order flows, never edit.)
  // Milestone 22: a status-only patch by anyone who is NOT the
  // seller or the team used to skip the ownership check entirely,
  // so a buyer from a cancelled order months ago could flip a live
  // listing to 'sold' (or a reserved one back to 'active') just by
  // calling this helper. The move must now match the caller's own
  // order on this listing: 'reserved' only while their order is
  // reserved/paid, 'sold' only once it is delivered/released, and
  // 'active' only once it is cancelled/refunded with no other open
  // order on the listing. The database trigger enforces the same
  // mapping (milestone-22.sql); this refuses it in the app first.
  const keys = Object.keys(clean);
  const isStatusOnly = keys.length === 1 && keys[0] === "status";
  if (isStatusOnly) {
    const listing = await fetchListing(id);
    if (!listing) throw new Error("Listing not found.");
    const { data: authData } = await supabase.auth.getUser();
    const caller = authData?.user || null;
    const isOwner = caller?.email === OWNER_EMAIL;
    if (caller && (isOwner || caller.id === listing.seller_id)) {
      // Seller / team: any status move the trigger allows.
    } else {
      if (!caller) throw new Error("Sign in first to change a listing.");
      const allowed = await statusMoveAllowedForParticipant(id, caller.id, clean.status);
      if (!allowed) {
        throw new Error("Only the seller can change a listing's status.");
      }
    }
  }
  if (!isStatusOnly) {
    const listing = await fetchListing(id);
    if (!listing) throw new Error("Listing not found.");
    const { data: authData } = await supabase.auth.getUser();
    const caller = authData?.user || null;
    const isOwner = caller?.email === OWNER_EMAIL;
    if (!caller || (!isOwner && caller.id !== listing.seller_id)) {
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
  // Count, don't fetch (see fetchOpenOrderCount): a listing with
  // more than 100 orders could otherwise be put back to active
  // while a live order sat past the first page.
  if ((await fetchOpenOrderCount(id)) > 0) {
    throw new Error(
      "This item has an open order on it — it stays reserved until that order is cancelled, delivered or refunded."
    );
  }
  return updateListing(id, { status: "active" });
}

export async function deleteListing(id) {
  if (!supabase || !id) throw new Error("Missing listing.");
  // Only the listing's seller — or the PulseMarket team — may
  // delete it. updateListing checks this; deleteListing had no
  // app-side check at all, so any signed-in caller could delete
  // another student's listing (RLS was the only backstop).
  const listing = await fetchListing(id);
  if (!listing) throw new Error("Listing not found.");
  const { data: authData } = await supabase.auth.getUser();
  const caller = authData?.user || null;
  const isOwner = caller?.email === OWNER_EMAIL;
  if (!caller || (!isOwner && caller.id !== listing.seller_id)) {
    throw new Error("Only the seller can delete this listing.");
  }
  // Deleting a listing cascades in the database: every order for it
  // (and their handoff, checkpoints and evidence) is deleted too.
  // Refuse while any live order history exists — a seller with an
  // order on the listing marks it sold instead. Only a listing whose
  // orders were all cancelled may be deleted. Count, don't fetch:
  // the old code fetched the first 100 orders, so a listing with
  // more than 100 orders could be deleted while a live order sat
  // past the first page.
  const { count, error: ordersError } = await supabase
    .from("orders")
    .select("id", { count: "exact", head: true })
    .eq("listing_id", id)
    .neq("status", "cancelled");
  if (ordersError) throw ordersError;
  if ((count || 0) > 0) {
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
    // "(copy)" is 7 characters — a title of 114+ characters would
    // push the copy over the 120-character limit and
    // createListingRow would refuse it. Truncate so a long-titled
    // listing can still be duplicated.
    title: `${listing.title} (copy)`.slice(0, 120),
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
  // Read the live count first: the views number the caller passes
  // in is whatever the page last rendered, and a crafted call could
  // pass views=999999 and jump the count in one write. (Two viewers
  // at the same instant can still lose one increment — views are
  // cosmetic, not money.)
  const fresh = await fetchListing(listing.id);
  const current = fresh?.views ?? listing.views ?? 0;
  await supabase
    .from("listings")
    .update({ views: (current || 0) + 1 })
    .eq("id", listing.id);
}

// Boost: records the tier and the expiry. No money moves yet — boost
// payment is demo until real payments go live (Milestone 6).
//
// Milestone 20 (M-2): a boost is no longer self-granted. The
// purchase_boost RPC records a pending boost_purchases row (the team
// confirms the payment in /admin, then the boost is applied), so a
// seller can no longer set a free 72h boost by direct API and renew
// it forever. The RPC lives in the Milestone 20 SQL; until that SQL
// runs it does not exist, so fall back to the old direct update —
// but ONLY when the RPC is missing (PGRST202 / 42883). Any other
// error is re-thrown. On RPC success the listing is NOT boosted yet:
// the plain message says so, and ListingDetail shows it instead of
// "Boosted until …".
export async function boostListing(id, tierAmount) {
  const tier = BOOST_TIERS.find((t) => t.amount === tierAmount);
  if (!tier) throw new Error("Unknown boost tier.");
  try {
    const { error: rpcError } = await supabase.rpc("purchase_boost", {
      p_listing_id: id,
      p_tier: tier.amount,
    });
    if (rpcError) throw rpcError;
    const listing = await fetchListing(id);
    return {
      ...(listing || { id }),
      boostRequested: true,
      boostMessage:
        "Boost requested — the team will confirm once payment is received.",
    };
  } catch (err) {
    const code = String(err?.code || "");
    const message = String(err?.message || "");
    const rpcMissing =
      code === "PGRST202" ||
      code === "42883" ||
      /could not find the function/i.test(message) ||
      /function .*purchase_boost.* does not exist/i.test(message);
    if (!rpcMissing) throw err;
    // RPC not switched on yet — the old direct update runs instead.
  }
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

// Milestone 20 (M-2): the team's boost queue — pending
// boost_purchases rows, oldest first, so the earliest request is
// confirmed first. Team only; the table and the RPC arrive with
// the Milestone 20 SQL, so until then this throws and /admin shows
// a plain note instead of a queue.
export async function fetchBoostRequests() {
  if (!supabase) throw new Error("Supabase is not configured.");
  await requireOwner();
  const { data, error } = await supabase
    .from("boost_purchases")
    .select("*")
    .eq("status", "pending_payment")
    .order("created_at", { ascending: true });
  if (error) throw error;
  return data || [];
}

// Milestone 20 (M-2): confirm a pending boost purchase. Marks the
// row 'paid', then applies the boost to the listing (same tier and
// expiry the old direct path set). No bank details anywhere — the
// team confirms the payment arrived by hand outside the app. If the
// boost itself fails after the row is marked paid, the error says so
// plainly and confirming again retries the boost (the row is
// already paid, so it is not marked twice).
export async function confirmBoostPurchase(row) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!row?.id) throw new Error("Missing boost request.");
  await requireOwner();
  const tierAmount =
    row.boost_tier ?? row.tier ?? row.amount ?? row.tier_amount ?? null;
  const tier = BOOST_TIERS.find((t) => t.amount === Number(tierAmount));
  if (!tier || !row.listing_id) {
    throw new Error(
      "Boost request is missing its tier or listing — apply the boost by hand."
    );
  }
  // Marking paid is the claim on this request: it must match a row
  // still 'pending_payment', or a second confirm (double-tap, or two
  // team members at once) would silently pass and re-apply the boost
  // below. A retry after a FAILED apply still works: the row is
  // already paid, so this update matches nothing — but the listing
  // then carries no trace of this tier, so the apply runs again.
  const { data: markedPaid, error: paidError } = await supabase
    .from("boost_purchases")
    .update({ status: "paid" })
    .eq("id", row.id)
    .eq("status", "pending_payment")
    .select("id");
  if (paidError) throw paidError;
  const claimed = (markedPaid?.length || 0) > 0;
  // A second confirm of the same request (double-tap, or two team
  // members at once) must not extend the boost: the row is already
  // 'paid', so the update above matched nothing — but the boost may
  // already be live from the first confirm. Skip re-applying
  // whenever ANY boost is currently live on the listing — a stale
  // re-confirm of a different tier used to overwrite the live boost
  // with this row's tier. A retry after a FAILED apply still works:
  // the listing is not boosted then, so it applies.
  const listing = await fetchListing(row.listing_id);
  if (!listing) {
    // The listing is gone (deleted) — the boost can never apply, so
    // say so plainly instead of the generic "marked paid but did not
    // apply" message, which invites confirming again forever.
    throw new Error(
      "This listing no longer exists — the boost cannot be applied. Refund the buyer if they paid."
    );
  }
  if (
    listing.boosted_until &&
    new Date(listing.boosted_until).getTime() > Date.now()
  ) {
    // A re-confirm of a row that is ALREADY paid (claimed is false)
    // is harmless: the boost is already live from the first
    // confirm, so report success. But if THIS confirm just claimed
    // the row (claimed is true), the seller has paid for a second
    // boost while one is live — and this confirm would mark it paid
    // and return success without applying anything, keeping the
    // money for a boost the seller never got. Refuse plainly so the
    // team refunds it instead.
    if (claimed) {
      throw new Error(
        "This listing already has a live boost — confirming this purchase would take the money without applying a new boost. Refund the buyer instead."
      );
    }
    return true;
  }
  if (!claimed && listing && listing.boost_tier === tier.amount && listing.boosted_until) {
    // Already paid AND this tier was already applied for this
    // listing (its boost has since expired): confirming again
    // would grant a fresh boost for free. Refuse plainly — the
    // team can apply a new boost by hand if one is really needed.
    // (A failed apply leaves no such trace on the listing, so a
    // genuine retry still reaches the apply below.)
    throw new Error(
      "This boost was already confirmed and its boost has ended — confirming again would grant a new boost for free. Apply a new boost by hand if one is needed."
    );
  }
  try {
    await updateListing(
      row.listing_id,
      {
        boost_tier: tier.amount,
        boosted_until: new Date(
          Date.now() + tier.hours * 60 * 60 * 1000
        ).toISOString(),
      },
      { allowBoost: true }
    );
  } catch (err) {
    throw new Error(
      `Boost marked paid, but the boost itself did not apply (${err?.message || "try confirming again"}).`
    );
  }
  return true;
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
  // A listing holds at most 4 photos — passing more used to upload
  // all of them and silently drop the extras.
  if (!dataUrls || dataUrls.length === 0) {
    throw new Error("Add at least 1 photo.");
  }
  if (dataUrls.length > 4) {
    throw new Error("A listing can have at most 4 photos.");
  }
  const urls = [];
  const uploadedPaths = [];
  try {
    for (let i = 0; i < dataUrls.length; i++) {
      const blob = await dataUrlToBlob(dataUrls[i]);
      if (blob.size > 10 * 1024 * 1024) {
        throw new Error("That photo is too big — keep listing photos under 10MB.");
      }
      // Milestone 20 (APP-10): the file must actually be a photo —
      // a renamed video or document used to sail through on its MIME
      // type alone. Same magic-byte check as the waybill photos.
      await assertRealPhoto(blob, "listing");
      const path = `${userId}/${Date.now()}-${i}.jpg`;
      const { error } = await supabase.storage
        .from(LISTING_PHOTOS_BUCKET)
        .upload(path, blob, { contentType: "image/jpeg", upsert: false });
      if (error) throw error;
      uploadedPaths.push(path);
      const { data } = supabase.storage
        .from(LISTING_PHOTOS_BUCKET)
        .getPublicUrl(path);
      urls.push(data.publicUrl);
    }
  } catch (err) {
    // A failure part-way used to leave the photos already uploaded
    // orphaned in the bucket. Remove them before rethrowing, so a
    // failed publish leaves nothing behind.
    if (uploadedPaths.length > 0) {
      await supabase.storage.from(LISTING_PHOTOS_BUCKET).remove(uploadedPaths);
    }
    throw err;
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
