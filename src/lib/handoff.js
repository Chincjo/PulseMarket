// Milestone 7 — Face-to-face handoff: seller code + QR + photo proof
// + dual confirm. Every function returns null / [] and logs the error
// when Supabase is not configured or the tables do not exist yet (owner
// has not run supabase/milestone-7.sql), so the app says so honestly
// instead of crashing.
//
// Flow (see supabase/milestone-7.sql and milestone-14.sql):
//   1. Seller opens the handoff: ensureSellerCode() creates the
//      one-time PM-XXXXXX code. It lives in the handoff_codes table
//      (seller-only) — NEVER on the order row, because the buyer can
//      read the order and would otherwise see the code without
//      meeting the seller. The seller shows it (big text + a QR code
//      made on their own phone — nothing leaves the device).
//   2. Buyer scans / types the code: scanSellerCode() checks it
//      server-side (verify_seller_code RPC), so the buyer never reads
//      the code from the database. 5 wrong guesses locks the handoff
//      and flags the attempting account.
//   3. Both sides take a handover photo with the in-app camera:
//      uploadHandoffPhoto().
//   4. Both sides confirm: confirmHandoff(). Only then is the release
//      unblocked — releaseOrder / confirmDelivery in orders.js enforce
//      that with handoffComplete().
import { supabase } from "./supabase";
import { OWNER_EMAIL } from "./payments";
import { assertRealPhoto } from "./shipping";

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
// The code is stored in handoff_codes (seller-only, see
// supabase/milestone-14.sql), never on the order row: the buyer reads
// the order, so a code stored there would be visible to them without
// meeting the seller. The returned order object carries the code
// in-memory (seller_code) so the Handoff page can show it and build
// the QR code — it is not saved on the order.
export async function ensureSellerCode(orderId) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.delivery_method !== "meetup") {
    throw new Error("This handoff is only for meet-in-person orders.");
  }
  // Only the seller may open (or create) the code. The database
  // refuses a buyer here too, but the app must not even ask: a buyer
  // calling this used to get a raw database error back instead of a
  // plain refusal, and the intent — the code is the seller's to show
  // — belongs in the app as well as the policy.
  const userId = await currentUserId();
  if (!userId || userId !== order.seller_id) {
    throw new Error("Only the seller can open the seller code for this order.");
  }
  if (order.handoff_locked) {
    throw new Error("This handoff is locked — contact support.");
  }
  if (["cancelled", "refunded", "released"].includes(order.status)) {
    throw new Error("This order is closed — there is no handoff to open.");
  }
  // Night deep check 2026-11-27: a frozen order (open dispute) must
  // not start a handoff — the code would let the seller show it and
  // the buyer scan it while the team is still reviewing.
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  const { data: existing, error: readError } = await supabase
    .from("handoff_codes")
    .select("code")
    .eq("order_id", orderId)
    .maybeSingle();
  if (readError) throw readError;
  if (existing?.code) return { ...order, seller_code: existing.code };
  // A code collision (unique index) is rare; retry with a fresh code.
  // A second device racing the first hits the same conflict — read
  // the code that won instead of failing.
  let lastError = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    const code = generateSellerCode();
    const { error } = await supabase
      .from("handoff_codes")
      .insert({ order_id: orderId, code });
    if (!error) return { ...order, seller_code: code };
    lastError = error;
    if (error?.code !== "23505") break;
    const { data: raced } = await supabase
      .from("handoff_codes")
      .select("code")
      .eq("order_id", orderId)
      .maybeSingle();
    if (raced?.code) return { ...order, seller_code: raced.code };
  }
  throw lastError || new Error("Could not create the seller code. Try again.");
}

// The BUYER calls this with the code they scanned or typed from the
// seller's phone. The code is checked server-side (verify_seller_code
// RPC, supabase/milestone-14.sql): the buyer never reads the code
// from the database, so it cannot be looked up without meeting the
// seller. A match marks the handoff scanned. A wrong code returns
// false — the RPC counted it and logged it, and the order is re-read
// here to say how many tries are left (or that the handoff locked
// at 5 wrong attempts and the account was flagged).
export async function scanSellerCode(orderId, code) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const typed = String(code || "").trim().toUpperCase();
  if (!typed) throw new Error("Type the seller code shown on the seller's phone.");
  const { data, error } = await supabase.rpc("verify_seller_code", {
    p_order_id: orderId,
    p_code: typed,
  });
  if (error) throw new Error(error.message || "Could not check the seller code. Try again.");
  if (data) return readOrder(orderId);
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.handoff_locked) {
    throw new Error("Too many wrong codes — this handoff is locked.");
  }
  const left = Math.max(0, MAX_CODE_ATTEMPTS - (order.code_attempts || 0));
  throw new Error(
    `Wrong code — ${left} ${left === 1 ? "try" : "tries"} left before this handoff locks.`
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
  // A handover photo is frozen once that side has confirmed — the
  // evidence cannot be swapped after the handoff is agreed — and a
  // closed order has no handoff left to photograph. The database
  // refuses the swap too; refuse here first so the photo is never
  // even uploaded.
  const confirmedField = role === "buyer" ? "buyer_confirmed" : "seller_confirmed";
  if (order[confirmedField]) {
    throw new Error("You already confirmed this handoff — the photo cannot be changed now.");
  }
  if (["cancelled", "refunded", "released"].includes(order.status)) {
    throw new Error("This order is closed — there is no handoff to photograph.");
  }
  // Night deep check 2026-11-27: no handoff evidence may change
  // while a dispute is open — the photo is part of the meetup
  // proof the team is reviewing.
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  const blob = await dataUrlToBlob(dataUrl);
  // A handoff photo with no checks used to accept any file at any
  // size. Same 10MB cap and magic-byte check as the waybill photos.
  if (blob.size > 10 * 1024 * 1024) {
    throw new Error("That photo is too big — keep photos under 10MB.");
  }
  await assertRealPhoto(blob, "handoff");
  // Timestamped path, never overwritten: the old fixed path with
  // upsert:true let the bytes behind a frozen photo URL be swapped
  // after confirming. A retake writes a new file and the order row
  // points at it; the old file is simply orphaned.
  const path = `${userId}/handoff-${orderId}-${role}-${Date.now()}.jpg`;
  const { error } = await supabase.storage
    .from(EVIDENCE_MEDIA_BUCKET)
    .upload(path, blob, { contentType: "image/jpeg", upsert: false });
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
  // Same closed-order guard as uploadHandoffPhoto: confirming a
  // handoff on a closed order writes confirmations that can never
  // be used (release / delivery refuse closed orders).
  if (["cancelled", "refunded", "released"].includes(order.status)) {
    throw new Error("This order is closed — there is no handoff to confirm.");
  }
  // Night deep check 2026-11-27: a frozen order (open dispute) must
  // not gain handoff confirmations — a seller could otherwise get
  // the buyer to scan + confirm after a "never received it" dispute
  // was filed, and the team would see "handoff complete" with no
  // way to know it happened after the filing. The database (M23)
  // refuses it too.
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
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
  const updated = await updateOrder(orderId, { [field]: true });
  // Night deep check 2026-11-27: confirmations are plain booleans
  // with no timestamp on the order, so the team could not tell a
  // confirm that happened after a dispute was filed from one
  // before it. Log it (best effort, timestamped) so the audit
  // trail shows when each side confirmed.
  await logSecurityEvent(
    orderId,
    userId,
    "handoff_confirmed",
    `Handoff confirmed by the ${role} for order ${order.code}.`
  );
  return updated;
}

// ---------------------------------------------------------------------------
// Locked handoffs — team recovery.
// ---------------------------------------------------------------------------
// Five wrong codes locks the handoff, and until now nothing in the
// app could ever unlock it: the buyer cannot scan, the seller cannot
// re-issue a code, and a held meetup order can neither be delivered
// nor released without the handoff — so the money sat frozen in
// hold for ever. Only the PulseMarket team unlocks it (the database
// trigger lets the owner write handoff_locked / code_attempts, and
// the orders RLS lets the owner update the order). Unlocking resets
// the attempt count so the buyer can try the code again. It does
// NOT unflag the buyer — the flag stays for the team to judge.
export async function unlockHandoff(orderId) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data: user } = await supabase.auth.getUser();
  if (!user?.user || user.user.email !== OWNER_EMAIL) {
    throw new Error("Only the PulseMarket team can unlock a handoff.");
  }
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (!order.handoff_locked && !(order.code_attempts || 0)) return order;
  const updated = await updateOrder(orderId, {
    handoff_locked: false,
    code_attempts: 0,
  });
  await logSecurityEvent(
    orderId,
    user.user.id,
    "handoff_unlocked",
    `Handoff unlocked by the PulseMarket team for order ${order.code} — the buyer can try the seller code again.`
  );
  return updated;
}

// Team-only read: every order whose handoff is locked, for /admin.
export async function fetchLockedHandoffs() {
  if (!supabase) throw new Error("Supabase is not configured.");
  const { data: user } = await supabase.auth.getUser();
  if (!user?.user || user.user.email !== OWNER_EMAIL) {
    throw new Error("This page is not available.");
  }
  const { data, error } = await supabase
    .from("orders")
    .select("*")
    .eq("handoff_locked", true)
    .order("created_at", { ascending: false });
  if (error) throw error;
  return data || [];
}

// ---------------------------------------------------------------------------
// Status — the order's handoff fields plus whether release is unblocked.
// ---------------------------------------------------------------------------

export async function getHandoffStatus(orderId) {
  const order = await readOrder(orderId);
  if (!order) return null;
  // The code comes from handoff_codes, which only the seller can
  // read — a buyer asking for the status gets null here, never the
  // code (see supabase/milestone-14.sql). Do not even send the query
  // as a buyer: the seller-only policy would refuse it, and the
  // status a buyer needs never includes the code.
  let code = null;
  const callerId = await currentUserId();
  if (supabase && callerId && callerId === order.seller_id) {
    const { data } = await supabase
      .from("handoff_codes")
      .select("code")
      .eq("order_id", orderId)
      .maybeSingle();
    code = data?.code || null;
  }
  // The delivery PIN belongs to the buyer only. This function does
  // not gate on meet-in-person, so a seller asking for the status of
  // a SHIPPING order would otherwise receive the full row including
  // the PIN — strip it for anyone but the buyer.
  let safeOrder = order;
  if (callerId !== order.buyer_id && order && "delivery_pin" in order) {
    const { delivery_pin: _delivery_pin, ...rest } = order;
    safeOrder = rest;
  }
  return {
    order: safeOrder,
    code,
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
