// Milestone 7 — Face-to-face handoff: seller code + QR + photo proof
// + dual confirm. Every function returns null / [] and logs the error
// when Supabase is not configured or the tables do not exist yet (owner
// has not run supabase/milestone-7.sql), so the app says so honestly
// instead of crashing.
//
// Flow (see supabase/milestone-7.sql for the columns):
//   1. Seller opens the handoff: ensureSellerCode() creates the one-time
//      PM-XXXXXX code. The seller shows it (big text + a QR code made
//      on their own phone — nothing leaves the device).
//   2. Buyer scans / types the code: scanSellerCode(). 5 wrong guesses
//      locks the handoff and flags the attempting account.
//   3. Both sides take a handover photo with the in-app camera:
//      uploadHandoffPhoto().
//   4. Both sides confirm: confirmHandoff(). Only then is the release
//      unblocked — releaseOrder / confirmDelivery in orders.js enforce
//      that with handoffComplete().
import { supabase } from "./supabase";

export const EVIDENCE_MEDIA_BUCKET = "evidence-media";

// 5 wrong codes locks the handoff.
export const MAX_CODE_ATTEMPTS = 5;

// One-time seller code: 'PM-' + 6 uppercase letters/digits (no I, O,
// 0 or 1, so the code cannot be misread off a phone screen).
export function generateSellerCode() {
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

// Pure check on an order row — reused by other milestones' pages and
// by the release / delivery gates in orders.js. Shipping orders never
// need a handoff, so they are "complete" by this check.
export function handoffComplete(order) {
  if (!order) return false;
  if (order.delivery_method && order.delivery_method !== "meetup") return true;
  return Boolean(
    order.handoff_scanned_at &&
      order.handoff_photo_buyer &&
      order.handoff_photo_seller &&
      order.buyer_confirmed &&
      order.seller_confirmed
  );
}

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
  if (error) return dbError(error, "fetch order for handoff");
  return data;
}

async function updateOrder(id, patch) {
  const { data, error } = await supabase
    .from("orders")
    .update({ ...patch, updated_at: new Date().toISOString() })
    .eq("id", id)
    .select()
    .single();
  if (error) throw error;
  return data;
}

// Best-effort security-log write. A logging failure must never block
// the handoff itself, so errors are logged to the console and swallowed.
// Callers that must record an event (e.g. a blocked release) still throw
// their own error after calling this.
export async function logSecurityEvent(orderId, userId, action, detail) {
  if (!supabase || !orderId) return false;
  const { error } = await supabase.from("security_log").insert({
    order_id: orderId,
    user_id: userId || null,
    action,
    detail: detail || null,
  });
  if (error) {
    dbError(error, "write security log");
    return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Seller code
// ---------------------------------------------------------------------------

// Generates and stores the seller code the first time the handoff is
// opened for a meetup order. If a code already exists it is returned
// unchanged — the code is one-time per deal and must never be re-rolled.
export async function ensureSellerCode(orderId) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.delivery_method !== "meetup") {
    throw new Error("This handoff is only for meet-in-person orders.");
  }
  if (order.handoff_locked) {
    throw new Error("This handoff is locked — contact support.");
  }
  if (order.seller_code) return order;
  // A code collision (unique index) is rare; retry with a fresh code.
  let lastError = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      return await updateOrder(orderId, { seller_code: generateSellerCode() });
    } catch (err) {
      lastError = err;
      if (err?.code !== "23505") break;
    }
  }
  throw lastError || new Error("Could not create the seller code. Try again.");
}

// The BUYER calls this with the code they scanned or typed from the
// seller's phone. On a match the handoff is marked scanned. On a
// mismatch the attempt is counted and logged; at 5 wrong attempts the
// handoff locks, the attempting account is flagged, and a lock row is
// logged.
export async function scanSellerCode(orderId, code) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const typed = String(code || "").trim().toUpperCase();
  if (!typed) throw new Error("Type the seller code shown on the seller's phone.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  const userId = await currentUserId();
  if (userId && order.buyer_id !== userId) {
    throw new Error("Only the buyer can scan the seller code.");
  }
  if (order.handoff_locked) {
    throw new Error("This handoff is locked — contact support.");
  }
  if (order.handoff_scanned_at) {
    throw new Error("This handoff has already been scanned.");
  }
  if (typed === String(order.seller_code || "").toUpperCase()) {
    return updateOrder(orderId, { handoff_scanned_at: new Date().toISOString() });
  }

  const attempts = (order.code_attempts || 0) + 1;
  await logSecurityEvent(
    orderId,
    userId,
    "wrong_code",
    `Wrong seller code attempt ${attempts} of ${MAX_CODE_ATTEMPTS} for order ${order.code}.`
  );
  if (attempts >= MAX_CODE_ATTEMPTS) {
    await updateOrder(orderId, {
      code_attempts: attempts,
      handoff_locked: true,
    });
    // Flag the attempting account for the PulseMarket team to review.
    if (userId) {
      const { error } = await supabase
        .from("verifications")
        .update({ flagged: true })
        .eq("user_id", userId);
      if (error) dbError(error, "flag account after handoff lock");
    }
    await logSecurityEvent(
      orderId,
      userId,
      "handoff_locked",
      `Handoff locked after ${attempts} wrong seller codes for order ${order.code}.`
    );
    throw new Error("Too many wrong codes — this handoff is locked.");
  }
  await updateOrder(orderId, { code_attempts: attempts });
  throw new Error(
    `Wrong code — ${MAX_CODE_ATTEMPTS - attempts} ${MAX_CODE_ATTEMPTS - attempts === 1 ? "try" : "tries"} left before this handoff locks.`
  );
}

// ---------------------------------------------------------------------------
// Handover photos (in-app camera only — the page passes a data URL
// captured from <input type="file" accept="image/*" capture>).
// Stored at <user-id>/handoff-<orderId>-<role>.jpg in evidence-media;
// the public URL is saved on the order.
// ---------------------------------------------------------------------------

async function dataUrlToBlob(dataUrl) {
  const res = await fetch(dataUrl);
  return res.blob();
}

export async function uploadHandoffPhoto(orderId, role, dataUrl) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (role !== "buyer" && role !== "seller") {
    throw new Error("Choose buyer or seller for the handoff photo.");
  }
  if (!dataUrl) throw new Error("Take a photo first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  const userId = await currentUserId();
  if (!userId) throw new Error("Sign in first to upload a handoff photo.");
  const expectedId = role === "buyer" ? order.buyer_id : order.seller_id;
  if (userId !== expectedId) {
    throw new Error("Only your own side of the handoff can upload this photo.");
  }
  const blob = await dataUrlToBlob(dataUrl);
  const path = `${userId}/handoff-${orderId}-${role}.jpg`;
  const { error } = await supabase.storage
    .from(EVIDENCE_MEDIA_BUCKET)
    .upload(path, blob, { contentType: "image/jpeg", upsert: true });
  if (error) throw error;
  const { data } = supabase.storage
    .from(EVIDENCE_MEDIA_BUCKET)
    .getPublicUrl(path);
  const field = role === "buyer" ? "handoff_photo_buyer" : "handoff_photo_seller";
  await updateOrder(orderId, { [field]: data.publicUrl });
  return data.publicUrl;
}

// ---------------------------------------------------------------------------
// Dual confirm
// ---------------------------------------------------------------------------

// Sets buyer_confirmed or seller_confirmed — only the matching party,
// only after the code was scanned and that side's photo exists.
export async function confirmHandoff(orderId, role) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (role !== "buyer" && role !== "seller") {
    throw new Error("Choose buyer or seller to confirm the handoff.");
  }
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  const userId = await currentUserId();
  if (!userId) throw new Error("Sign in first to confirm the handoff.");
  const expectedId = role === "buyer" ? order.buyer_id : order.seller_id;
  if (userId !== expectedId) {
    throw new Error("Only your own side of the handoff can confirm it.");
  }
  if (!order.handoff_scanned_at) {
    throw new Error("Scan the seller code first.");
  }
  const photoField = role === "buyer" ? "handoff_photo_buyer" : "handoff_photo_seller";
  if (!order[photoField]) {
    throw new Error("Take your handoff photo first.");
  }
  const field = role === "buyer" ? "buyer_confirmed" : "seller_confirmed";
  return updateOrder(orderId, { [field]: true });
}

// ---------------------------------------------------------------------------
// Status — the order's handoff fields plus whether release is unblocked.
// ---------------------------------------------------------------------------

export async function getHandoffStatus(orderId) {
  const order = await readOrder(orderId);
  if (!order) return null;
  return {
    order,
    code: order.seller_code || null,
    scanned: Boolean(order.handoff_scanned_at),
    scannedAt: order.handoff_scanned_at || null,
    locked: Boolean(order.handoff_locked),
    attempts: order.code_attempts || 0,
    attemptsLeft: Math.max(0, MAX_CODE_ATTEMPTS - (order.code_attempts || 0)),
    buyerPhoto: Boolean(order.handoff_photo_buyer),
    sellerPhoto: Boolean(order.handoff_photo_seller),
    buyerPhotoUrl: order.handoff_photo_buyer || null,
    sellerPhotoUrl: order.handoff_photo_seller || null,
    buyerConfirmed: Boolean(order.buyer_confirmed),
    sellerConfirmed: Boolean(order.seller_confirmed),
    releaseUnblocked: handoffComplete(order),
  };
}
