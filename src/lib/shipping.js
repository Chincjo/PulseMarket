// Milestone 8 — Shipping: free-text transport, Waybill Snap proof,
// 50% shipping advance, checkpoints, delivery PIN, returns. Every
// read function returns null / [] and logs the error when the tables
// do not exist yet (owner has not run supabase/milestone-8.sql), so
// the app says so honestly instead of crashing. Write functions
// throw a clear Error when the caller is not allowed or the order is
// in the wrong state.
//
// THE TRANSPORT MODEL (no courier list anywhere): there is no list
// of couriers, no dropdown and no tier that restricts which transport
// a parcel may travel with. The seller types the transport name as
// free text — a courier (GIG Logistics, GUO Transport, DHL), a bus
// company (God is Good Motors), an airline (Air Peace flight) or any
// cargo company. orders.courier (text column, name unchanged) stores
// that free-text name, and orders.transport_ref stores the plate /
// flight number when the seller knows it. The transport is shown as
// "Transport" / "Sent with {name}", never as a choice from a list.
//
// Money model (manual escrow, same ledger as Milestone 6):
//   - The buyer pays the full total up front; the owner confirms the
//     transfer and the total sits in the seller's "held" bucket.
//   - Shipping proof: when the proof is COMPLETE (a waybill number
//     AND a receipt photo are present), half the shipping fee moves
//     held -> available as a 'shipping_advance' — whatever the
//     transport is called. A bus-park style proof (driver phone
//     only, no receipt) ships the order but earns NO advance. A
//     missing receipt photo earns no advance either.
//   - Returns are resolved by the PulseMarket team only (see
//     resolveReturn). Balances are SUM(amount) over wallet_ledger —
//     never stored.
import { supabase } from "./supabase";
import { confirmDelivery } from "./orders";
import { OWNER_EMAIL } from "./payments";
import { notifyUser } from "./notifications";

// Evidence photos (waybill, receipt, checkpoint) live in the
// evidence-media bucket created by Milestone 7, under <user-id>/,
// the same path pattern as listing photos.
export const EVIDENCE_BUCKET = "evidence-media";

export const CHECKPOINT_STATUSES = [
  { value: "picked_up", label: "Picked up" },
  { value: "left_origin", label: "Left origin" },
  { value: "stopped", label: "Stopped on the way" },
  { value: "arrived_terminal", label: "Arrived at terminal" },
  { value: "out_for_delivery", label: "Out for delivery" },
  { value: "ready_for_pickup", label: "Ready for pickup" },
  { value: "delivered", label: "Delivered" },
];

export const CHECKPOINT_LABELS = Object.fromEntries(
  CHECKPOINT_STATUSES.map((s) => [s.value, s.label])
);

export const RETURN_REASONS = [
  "Wrong item sent",
  "Item damaged",
  "Item not as described",
  "Item looks fake",
  "I changed my mind",
  "Item arrived too late",
  "Other",
];

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

async function currentUser() {
  if (!supabase) return null;
  const { data } = await supabase.auth.getUser();
  return data?.user || null;
}

async function readOrder(id) {
  if (!supabase || !id) return null;
  const { data, error } = await supabase
    .from("orders")
    .select("*")
    .eq("id", id)
    .maybeSingle();
  if (error) return dbError(error, "fetch order");
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

// Same paired-move shape as Milestone 6's ledger writes. Milestone
// 22 (APP-17 mirror): created_by is the student actually making the
// move — the seller claiming their advance, or the team resolving a
// return — not always the buyer. orders.js recordLedgerMove() was
// fixed the same way in Milestone 20; this copy still hardcoded the
// buyer, so team-resolved refunds and seller advances were
// attributed to the buyer in the audit trail. Falls back to the
// buyer only when no one is signed in (a timed/system call).
async function recordLedgerMove(order, moves) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const actor = (await currentUser())?.id || order.buyer_id;
  const rows = moves.map((m) => ({
    order_id: order.id,
    user_id: m.userId,
    bucket: m.bucket,
    kind: m.kind,
    amount: m.amount,
    note: m.note || null,
    created_by: actor,
  }));
  const { error } = await supabase.from("wallet_ledger").insert(rows);
  if (error) throw error;
}

// How much shipping advance has already been released to the seller
// for this order (sum of the 'available' shipping_advance entries).
async function advanceAlreadyReleased(orderId) {
  if (!supabase || !orderId) return 0;
  const { data, error } = await supabase
    .from("wallet_ledger")
    .select("amount")
    .eq("order_id", orderId)
    .eq("kind", "shipping_advance")
    .eq("bucket", "available");
  if (error) {
    dbError(error, "read shipping advance");
    return 0;
  }
  return (data || []).reduce((sum, r) => sum + (Number(r.amount) || 0), 0);
}

// Morning deep check 2026-11-28: the summed amount of one ledger
// leg (kind + bucket) for an order, or null when no such leg exists
// — same helper as orders.js ledgerMoveAmount. The paired-leg
// recoveries use it to prove the SECOND leg exists, for the right
// amount, before declaring a move complete.
async function ledgerMoveAmount(orderId, kind, bucket) {
  if (!supabase || !orderId) return null;
  const { data, error } = await supabase
    .from("wallet_ledger")
    .select("amount")
    .eq("order_id", orderId)
    .eq("kind", kind)
    .eq("bucket", bucket);
  if (error) {
    dbError(error, "read ledger move amount");
    return null;
  }
  if (!data || data.length === 0) return null;
  return data.reduce((sum, r) => sum + (Number(r.amount) || 0), 0);
}

// ---------------------------------------------------------------------------
// Delivery PIN
// ---------------------------------------------------------------------------

// 6 digits, leading zeros kept (it is stored and compared as text).
export function generateDeliveryPin() {
  const bytes = new Uint32Array(6);
  if (typeof crypto !== "undefined" && crypto.getRandomValues) {
    crypto.getRandomValues(bytes);
  } else {
    for (let i = 0; i < 6; i++) bytes[i] = Math.floor(Math.random() * 0xffffffff);
  }
  let pin = "";
  for (let i = 0; i < 6; i++) {
    pin += String(bytes[i] % 10);
  }
  return pin;
}

// ---------------------------------------------------------------------------
// Photo uploads (evidence-media bucket, Milestone 7)
// ---------------------------------------------------------------------------

// Accepts a File / Blob (from a camera capture input) or a data-URL
// string (from a FileReader preview). Returns the public URL.
async function toBlob(fileOrDataUrl) {
  if (typeof fileOrDataUrl === "string") {
    const res = await fetch(fileOrDataUrl);
    return res.blob();
  }
  return fileOrDataUrl;
}

export async function uploadEvidencePhoto(userId, orderId, fileOrDataUrl, label) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!fileOrDataUrl) return null;
  const blob = await toBlob(fileOrDataUrl);
  // A checkpoint / shipping photo with no checks used to accept any
  // file at any size — the waybill photos go through assertRealPhoto
  // and a 10MB cap, so these do too.
  if (blob.size > 10 * 1024 * 1024) {
    throw new Error("That photo is too big — keep photos under 10MB.");
  }
  await assertRealPhoto(blob, label || "checkpoint");
  const path = `${userId}/shipping/${orderId}-${label}-${Date.now()}.jpg`;
  const { error } = await supabase.storage
    .from(EVIDENCE_BUCKET)
    .upload(path, blob, { contentType: "image/jpeg", upsert: false });
  if (error) throw error;
  const { data } = supabase.storage.from(EVIDENCE_BUCKET).getPublicUrl(path);
  return data.publicUrl;
}

// Morning deep check 2026-11-28: best-effort removal of an uploaded
// photo by its public URL, so a failed order/checkpoint update does
// not leave an orphaned file behind. The storage path is the part of
// the URL after the bucket name. Never throws — cleanup must never
// mask the real error.
async function removeEvidencePhoto(publicUrl) {
  if (!supabase || !publicUrl) return;
  const marker = `/${EVIDENCE_BUCKET}/`;
  const at = String(publicUrl).indexOf(marker);
  if (at < 0) return;
  const path = String(publicUrl).slice(at + marker.length).split("?")[0];
  if (!path) return;
  try {
    await supabase.storage.from(EVIDENCE_BUCKET).remove([decodeURIComponent(path)]);
  } catch {
    // Orphaned file stays — storage hygiene only, never fatal.
  }
}

// The delivery PIN belongs to the buyer only (they share it with the
// driver at handover). Seller-facing reads strip it from the order
// object so the PIN never sits in the seller's page state — the
// database still returns the full row to a direct API call (see the
// coordinator's report: hiding it from a determined caller needs a
// server-side fetch), and the trigger already refuses any delivery
// confirmation that is not the buyer's. Buyer-only functions
// (confirmDeliveryWithPin) read the order through readOrder() and
// are untouched by this.
function withoutDeliveryPin(order) {
  if (!order || !("delivery_pin" in order)) return order;
  const { delivery_pin: _delivery_pin, ...rest } = order;
  return rest;
}

// ---------------------------------------------------------------------------
// Waybill Snap photo checks — cheap app-side friction against a fake
// shipping advance (no OCR anywhere in this flow, so these checks
// cannot prove the parcel exists; they only make the easy fakes fail).
//   1. The file must actually be a photo: JPEG / PNG / GIF / WebP /
//      HEIC magic bytes. A renamed video, PDF or text file uploaded
//      as "image/jpeg" used to sail through.
//   2. The waybill photo and the receipt photo must not be the same
//      file uploaded twice.
//   3. A waybill number may only ever be used for one order (checked
//      again below, before the proof is saved).
// ---------------------------------------------------------------------------
export async function assertRealPhoto(blob, label) {
  if (!blob || blob.size < 512) {
    throw new Error(
      `That ${label} photo does not look like a photo — take it again with the camera.`
    );
  }
  const head = new Uint8Array(await blob.slice(0, 12).arrayBuffer());
  const isJpeg = head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff;
  const isPng =
    head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47;
  const isGif =
    head[0] === 0x47 && head[1] === 0x49 && head[2] === 0x46 && head[3] === 0x38;
  const isWebp =
    head[0] === 0x52 &&
    head[1] === 0x49 &&
    head[2] === 0x46 &&
    head[3] === 0x46 &&
    head[8] === 0x57 &&
    head[9] === 0x45 &&
    head[10] === 0x42 &&
    head[11] === 0x50;
  // HEIC / HEIF (iPhone photos): bytes 4-7 are the "ftyp" box marker.
  const isHeic =
    head[4] === 0x66 && head[5] === 0x74 && head[6] === 0x79 && head[7] === 0x70;
  if (!isJpeg && !isPng && !isGif && !isWebp && !isHeic) {
    throw new Error(
      `That ${label} file does not look like a photo — take it again with the camera instead of uploading another kind of file.`
    );
  }
}

async function sameBytes(a, b) {
  if (!a || !b || a.size !== b.size) return false;
  const [x, y] = await Promise.all([a.arrayBuffer(), b.arrayBuffer()]);
  const xa = new Uint8Array(x);
  const ya = new Uint8Array(y);
  for (let i = 0; i < xa.length; i++) {
    if (xa[i] !== ya[i]) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Shipping proof — seller only, order must be 'held'.
// ---------------------------------------------------------------------------
//
// Waybill Snap is guided capture only: the seller photographs the
// waybill and types the number in themselves. There is NO OCR and no
// auto-fill anywhere in this flow.
export async function submitShippingProof(
  orderId,
  { waybillNumber, waybillPhoto, receiptPhoto, driverPhone, transportName, transportRef }
) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.seller_id !== user.id) {
    throw new Error("Only the seller can submit shipping proof for this order.");
  }
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  if (order.status !== "held") {
    // Retry path: the proof was already saved and the order already
    // shipped, but the advance never moved (an earlier attempt died
    // after shipping). Release it from the stored proof instead of
    // refusing outright.
    if (
      ["shipped", "delivered"].includes(order.status) &&
      order.waybill_number &&
      order.receipt_photo &&
      !order.shipping_advance_released
    ) {
      return retryShippingAdvance(orderId);
    }
    throw new Error(
      `This order is ${order.status} — shipping proof can only be submitted once the money is held.`
    );
  }
  if (order.delivery_method !== "shipping") {
    throw new Error("This order is a meet-in-person order — there is nothing to ship.");
  }
  // The transport is free text the seller types — a courier, a bus
  // company, an airline or any cargo company. It is required here
  // (the order carries the seller's stated transport from the
  // listing, but the seller confirms or corrects it at proof time),
  // and it is saved back onto the order with the proof.
  const cleanTransportName = String(transportName || "").trim();
  if (!cleanTransportName) {
    throw new Error("Type the name of the transport carrying this parcel.");
  }
  if (cleanTransportName.length > 120) {
    throw new Error("Keep the transport name under 120 characters.");
  }
  const cleanTransportRef = String(transportRef || "").trim();
  if (cleanTransportRef.length > 120) {
    throw new Error("Keep the plate / flight number under 120 characters.");
  }
  const waybill = String(waybillNumber || "").trim();
  if (!waybill) {
    throw new Error("Type in the waybill number from the paper waybill.");
  }
  if (waybill.length < 4) {
    throw new Error("That waybill number looks too short — type the full number from the paper waybill.");
  }
  if (waybill.length > 64) {
    throw new Error("Keep the waybill number under 64 characters.");
  }
  // One waybill number, one order: a number already used for another
  // order of this seller is either a typo or the same parcel being
  // "shipped" twice to take two advances. The check matches on the
  // waybill number + the same seller only — the transport name is
  // free text, so it is not part of the match. Best effort in the
  // app — the orders read policy only shows the caller their own
  // orders, so a cross-seller reuse is invisible here; the hard
  // backstop is the unique index on waybill_number alone
  // (orders_waybill_number_unique_idx, milestone-18.sql). The same
  // number with a different transport is a coincidence (transport
  // companies number parcels independently), so it does not count.
  if (supabase) {
    const { data: reuse, error: reuseError } = await supabase
      .from("orders")
      .select("id, code, seller_id")
      .eq("waybill_number", waybill)
      .neq("id", order.id)
      .limit(5);
    const hit = (reuse || []).find((r) => r.seller_id === user.id);
    if (!reuseError && hit) {
      throw new Error(
        `That waybill number was already used for order ${hit.code} — check the number on the paper waybill.`
      );
    }
    if (reuseError) {
      console.error("[PulseMarket] shipping proof: could not check waybill reuse:", reuseError.message || reuseError);
    }
  }
  const cleanDriverPhone = driverPhone ? String(driverPhone).trim() : "";
  if (cleanDriverPhone && !/^\+?[0-9][0-9 ()-]{6,14}$/.test(cleanDriverPhone)) {
    throw new Error("That driver phone number does not look right.");
  }
  if (!waybillPhoto) {
    throw new Error("Take a photo of the waybill — hold the paper steady, good light, all four corners visible.");
  }
  // The photos must really be photos, and the receipt must not be
  // the waybill photo uploaded a second time. Convert once here so
  // the checks and the uploads all see the same bytes.
  const waybillBlob = await toBlob(waybillPhoto);
  await assertRealPhoto(waybillBlob, "waybill");
  const receiptBlob = receiptPhoto ? await toBlob(receiptPhoto) : null;
  if (receiptBlob) {
    await assertRealPhoto(receiptBlob, "receipt");
    if (await sameBytes(waybillBlob, receiptBlob)) {
      throw new Error("The receipt photo looks identical to the waybill photo — take a photo of the receipt itself, not the waybill again.");
    }
  }

  const waybillUrl = await uploadEvidencePhoto(user.id, order.id, waybillBlob, "waybill");
  let receiptUrl = null;
  try {
    receiptUrl = receiptBlob
      ? await uploadEvidencePhoto(user.id, order.id, receiptBlob, "receipt")
      : null;
  } catch (err) {
    // The waybill photo is already up but the proof is not saved —
    // remove it so it does not sit orphaned in the bucket.
    await removeEvidencePhoto(waybillUrl);
    throw err;
  }

  // The advance is earned only with a complete proof: a waybill
  // number AND a receipt photo — whatever the transport is called.
  // A bus-park style proof (driver phone only, no receipt) and a
  // missing receipt photo earn no advance — the order still ships.
  const proofComplete = Boolean(waybill) && Boolean(receiptUrl);
  const advanceAmount = Math.floor((Number(order.shipping_fee) || 0) / 2);

  // STEP 1 — save the proof and ship the order FIRST. The database
  // (supabase/milestone-15.sql) only pays a shipping advance once
  // the waybill number + receipt photo are already on the order, so
  // an advance can no longer be taken with no proof behind it. The
  // old order (advance first, proof second) could not satisfy that
  // rule at all.
  let shipped;
  try {
    shipped = await updateOrder(orderId, {
      courier: cleanTransportName,
      transport_ref: cleanTransportRef || null,
      waybill_number: waybill,
      waybill_photo: waybillUrl,
      receipt_photo: receiptUrl,
      driver_phone: cleanDriverPhone || null,
      shipping_proof_at: new Date().toISOString(),
      delivery_pin: generateDeliveryPin(),
      status: "shipped",
    });
  } catch (err) {
    // Lost a race: another device already shipped this order with
    // its own proof. The order is shipped — say so instead of
    // failing, and let the tracking page retry the advance if one
    // is still due.
    const fresh = await readOrder(orderId);
    if (fresh && ["shipped", "delivered"].includes(fresh.status) && fresh.waybill_number) {
      // The other device's proof is the one saved — ours would sit
      // orphaned in the bucket. Remove it before returning.
      await removeEvidencePhoto(waybillUrl);
      await removeEvidencePhoto(receiptUrl);
      return {
        order: withoutDeliveryPin(fresh),
        advanceReleased: Boolean(fresh.shipping_advance_released),
        reason: "Shipping proof was already submitted for this order — the order is shipped.",
      };
    }
    // Morning deep check 2026-11-28: the waybill number may already
    // be used by another seller (the app-side reuse check cannot see
    // other sellers' orders, and the unique index is the backstop).
    // Say so plainly instead of surfacing the raw database error.
    if (err?.code === "23505") {
      await removeEvidencePhoto(waybillUrl);
      await removeEvidencePhoto(receiptUrl);
      throw new Error(
        "That waybill number is already used for another order — check the number on the paper waybill and try again."
      );
    }
    // Any other failure: the proof is not saved, so the photos just
    // uploaded would sit orphaned in the bucket. Remove them.
    await removeEvidencePhoto(waybillUrl);
    await removeEvidencePhoto(receiptUrl);
    throw err;
  }

  // STEP 2 — pay the advance, only for a complete proof. An advance
  // row can already exist while the order has no waybill saved (the
  // old flow moved the money, then the order update never landed):
  // in that case just carry on without moving money again. Any other
  // failure here must NOT throw the whole submission away — the
  // order is already shipped, so report the advance as pending and
  // let the seller retry it from the tracking page.
  let advanceReleased = false;
  let advancePending = false;
  let reason;
  if (proofComplete && advanceAmount > 0) {
    const alreadyAdvanced =
      shipped.shipping_advance_released || (await advanceAlreadyReleased(order.id)) > 0;
    if (alreadyAdvanced) {
      advanceReleased = true;
      reason = `Proof recorded — the 50% shipping advance (${advanceAmount.toLocaleString("en-NG")} naira) was already in your available balance. The rest is released when the buyer confirms delivery.`;
    } else {
      try {
        await recordLedgerMove(shipped, [
          {
            userId: shipped.seller_id,
            bucket: "held",
            kind: "shipping_advance",
            amount: -advanceAmount,
            note: `Shipping advance (50%) for order ${shipped.code}`,
          },
          {
            userId: shipped.seller_id,
            bucket: "available",
            kind: "shipping_advance",
            amount: advanceAmount,
            note: `Shipping advance (50%) for order ${shipped.code}`,
          },
        ]);
        advanceReleased = true;
        reason = `Proof complete — 50% of the shipping fee (${advanceAmount.toLocaleString("en-NG")} naira) has been released to your available balance. The rest is released when the buyer confirms delivery.`;
      } catch (err) {
        if (err?.code === "23505") {
          // Another device paid the advance a moment ago — but a
          // 23505 only proves ONE leg collided. A half-written pair
          // (held leg only, no available leg) must not be reported
          // as released: verify the available leg first, mirroring
          // retryShippingAdvance below. If it is missing, the
          // advance is pending and the seller retries it from the
          // tracking page (which then reports the half-move plainly).
          if ((await advanceAlreadyReleased(order.id)) > 0) {
            advanceReleased = true;
            reason = `Proof complete — 50% of the shipping fee (${advanceAmount.toLocaleString("en-NG")} naira) has been released to your available balance. The rest is released when the buyer confirms delivery.`;
          } else {
            advancePending = true;
            reason =
              "Proof recorded and the order is now shipped — but the 50% shipping advance is only half recorded. Use “Retry shipping advance” on the tracking page to release it.";
          }
        } else {
          advancePending = true;
          reason =
            "Proof recorded and the order is now shipped — but the 50% shipping advance could not be released yet. Use “Retry shipping advance” on the tracking page to release it.";
        }
      }
    }
  } else if (!receiptUrl) {
    reason = cleanDriverPhone
      ? "Proof recorded and the order is now shipped — but this proof has only a driver phone and no receipt photo, so no shipping advance was released. The full shipping fee is released when the buyer confirms delivery."
      : "Proof recorded and the order is now shipped — but there is no receipt photo, so no shipping advance was released. The full shipping fee is released when the buyer confirms delivery.";
  } else {
    reason =
      "Proof recorded and the order is now shipped. The shipping fee is released when the buyer confirms delivery.";
  }

  // STEP 3 — record that the advance moved. Best effort: on the old
  // database this flag-only update is refused (it needs the
  // held -> shipped move), so the flag stays false until the
  // database update lands — the tracking page then offers the retry.
  if (advanceReleased) {
    try {
      await updateOrder(orderId, { shipping_advance_released: true });
    } catch (err) {
      dbError(err, "mark shipping advance released");
    }
  }
  const fresh = (await readOrder(orderId)) || shipped;
  // Seller-facing return: the buyer-only delivery PIN is stripped
  // (see withoutDeliveryPin above).
  return { order: withoutDeliveryPin(fresh), advanceReleased, advancePending, reason };
}

// Release a shipping advance that is still owed after the proof was
// already saved — used when an earlier submit shipped the order but
// the advance insert failed (or the old database refused it), and by
// the "Retry shipping advance" button on the tracking page. The
// proof on the order is re-checked: no waybill + receipt, no advance.
export async function retryShippingAdvance(orderId) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.seller_id !== user.id) {
    throw new Error("Only the seller can release the shipping advance for this order.");
  }
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  if (!["shipped", "delivered"].includes(order.status)) {
    throw new Error(
      `This order is ${order.status} — the shipping advance is released once the order has shipped.`
    );
  }
  if (order.shipping_advance_released) {
    return {
      order: withoutDeliveryPin(order),
      advanceReleased: true,
      reason: "The 50% shipping advance was already released to your available balance.",
    };
  }
  if (!order.waybill_number || !order.receipt_photo) {
    throw new Error("No shipping advance is due for this proof — it needs a waybill number and a receipt photo.");
  }
  const advanceAmount = Math.floor((Number(order.shipping_fee) || 0) / 2);
  if (advanceAmount <= 0) {
    throw new Error("No shipping advance is due for this order.");
  }
  if ((await advanceAlreadyReleased(order.id)) <= 0) {
    try {
      await recordLedgerMove(order, [
        {
          userId: order.seller_id,
          bucket: "held",
          kind: "shipping_advance",
          amount: -advanceAmount,
          note: `Shipping advance (50%) for order ${order.code}`,
        },
        {
          userId: order.seller_id,
          bucket: "available",
          kind: "shipping_advance",
          amount: advanceAmount,
          note: `Shipping advance (50%) for order ${order.code}`,
        },
      ]);
    } catch (err) {
      if (err?.code !== "23505") throw err;
      // Another device paid it a moment ago — carry on to the flag.
      // Night deep check 2026-11-27: a 23505 on the held leg only
      // proves the HELD leg exists. A half-written pair (held leg
      // only, no available leg) used to be marked released here,
      // and the later release then failed the ledger trigger's
      // held-sum backstop. Verify the available leg too — if it is
      // missing, the team has to complete the pair by hand.
      if ((await advanceAlreadyReleased(order.id)) <= 0) {
        throw new Error("The shipping advance is only half recorded — ask the PulseMarket team to check it.");
      }
    }
  }
  try {
    await updateOrder(orderId, { shipping_advance_released: true });
  } catch {
    // The flag-only update needs supabase/milestone-15.sql. The
    // money has still moved — say so plainly instead of failing.
    return {
      order: withoutDeliveryPin((await readOrder(orderId)) || order),
      advanceReleased: true,
      reason: `The 50% shipping advance (${advanceAmount.toLocaleString("en-NG")} naira) is in your available balance. The tracking page will show it once the database update is run.`,
    };
  }
  return {
    order: withoutDeliveryPin((await readOrder(orderId)) || order),
    advanceReleased: true,
    reason: `Proof complete — 50% of the shipping fee (${advanceAmount.toLocaleString("en-NG")} naira) has been released to your available balance. The rest is released when the buyer confirms delivery.`,
  };
}

// ---------------------------------------------------------------------------
// Checkpoints — seller only.
// ---------------------------------------------------------------------------

export async function addCheckpoint(orderId, { status, location, note, photo }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.seller_id !== user.id) {
    throw new Error("Only the seller can add a checkpoint for this order.");
  }
  // A frozen order (open dispute) takes no new checkpoints — the
  // seller could otherwise spam the buyer with parcel updates (each
  // one fires a notification) while the team is reviewing the order.
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  if (!["shipped", "delivered"].includes(order.status)) {
    throw new Error(
      `This order is ${order.status} — checkpoints start once the parcel has shipped.`
    );
  }
  if (!CHECKPOINT_LABELS[status]) {
    throw new Error("Choose a checkpoint status.");
  }
  if (location && String(location).trim().length > 120) {
    throw new Error("Keep the location under 120 characters.");
  }
  if (note && String(note).trim().length > 280) {
    throw new Error("Keep the note under 280 characters.");
  }
  // Night deep check 2026-11-27: the database refuses backwards
  // checkpoints and a repeated 'delivered', but it allows equal-rank
  // repeats — a seller could spam the same stop and fire a buyer
  // notification each time. Refuse an exact repeat of the latest
  // update, and the same status again within a minute. A failed
  // latest-read fails open here; the database is the backstop for
  // ordering, and a duplicate still costs the seller a tap, not the
  // buyer a notification storm.
  const { data: latest } = await supabase
    .from("shipping_checkpoints")
    .select("status, location, note, created_at")
    .eq("order_id", order.id)
    .order("created_at", { ascending: false })
    .limit(1);
  const last = (latest || [])[0];
  if (last) {
    const cleanLocation = location ? String(location).trim() : null;
    const cleanNote = note ? String(note).trim() : null;
    if (
      last.status === status &&
      (last.location || null) === cleanLocation &&
      (last.note || null) === cleanNote
    ) {
      throw new Error("That update is already on the tracking page.");
    }
    if (
      last.status === status &&
      Date.now() - new Date(last.created_at).getTime() < 60 * 1000
    ) {
      throw new Error("Wait a moment before adding the same update again.");
    }
  }
  let photoUrl = null;
  if (photo) {
    photoUrl = await uploadEvidencePhoto(user.id, order.id, photo, "checkpoint");
  }
  let inserted;
  try {
    const { data, error } = await supabase
      .from("shipping_checkpoints")
      .insert({
        order_id: order.id,
        status,
        location: location ? String(location).trim() : null,
        note: note ? String(note).trim() : null,
        photo: photoUrl,
      })
      .select()
      .single();
    if (error) throw error;
    inserted = data;
  } catch (err) {
    // The photo is already up but the checkpoint is not saved —
    // remove it so it does not sit orphaned in the bucket.
    await removeEvidencePhoto(photoUrl);
    throw err;
  }
  const data = inserted;
  // Milestone 10: tell the buyer the parcel moved.
  notifyUser(order.buyer_id, {
    kind: "checkpoint",
    title: "Parcel update",
    body: `${CHECKPOINT_LABELS[status]}${location ? " — " + location : ""}`,
    link: `/tracking/${order.id}`,
    orderId: order.id,
  });
  return data;
}

export async function fetchCheckpoints(orderId) {
  if (!supabase || !orderId) return [];
  const { data, error } = await supabase
    .from("shipping_checkpoints")
    .select("*")
    .eq("order_id", orderId)
    .order("created_at", { ascending: true });
  if (error) {
    dbError(error, "fetch checkpoints");
    return [];
  }
  return data || [];
}

// Order + checkpoints together, for the tracking page. The buyer
// sees the delivery PIN; anyone else gets the order without it.
export async function fetchTracking(orderId) {
  const order = await readOrder(orderId);
  if (!order) return null;
  const checkpoints = await fetchCheckpoints(orderId);
  const viewer = await currentUser();
  const safeOrder =
    viewer && order.buyer_id === viewer.id ? order : withoutDeliveryPin(order);
  return { order: safeOrder, checkpoints };
}

// ---------------------------------------------------------------------------
// Rider details — seller-entered, same-city shipping orders only.
// The seller types the rider's (or driver's) name and phone for a
// same-city shipping order while it is held or shipped, so the buyer
// can call the rider instead of asking in chat. Same-city means the
// ship-to state AND country match the listing's state and country —
// the transport name plays no part in it. This writes through the
// normal order-update path; it moves no money and changes no status.
// NOTE: the database rider rule (supabase/m19/03-admin-rider-caps.sql)
// still names a courier — the SQL side needs aligning to this same
// location rule.
// ---------------------------------------------------------------------------

export async function updateRiderDetails(orderId, { riderName, riderPhone }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.seller_id !== user.id) {
    throw new Error("Only the seller can add rider details for this order.");
  }
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  if (order.delivery_method !== "shipping") {
    throw new Error("Rider details are only for shipping orders.");
  }
  // Same-city = ship-to state AND country match the listing's state
  // and country (the listing row is the seller's location — the
  // order only carries where it ships to). A failed listing read
  // refuses: same-city cannot be proved without it.
  const { data: listingRow } = await supabase
    .from("listings")
    .select("state, country")
    .eq("id", order.listing_id)
    .maybeSingle();
  const sameCity =
    Boolean(listingRow) &&
    Boolean(order.ship_to_state) &&
    order.ship_to_state === listingRow.state &&
    (order.ship_to_country || "Nigeria") === (listingRow.country || "Nigeria");
  if (!sameCity) {
    throw new Error("Rider details are only for same-city shipping orders — this parcel is going to another state or country.");
  }
  if (!["held", "shipped"].includes(order.status)) {
    throw new Error(
      `This order is ${order.status} — rider details can only be added while the money is held or the order has shipped.`
    );
  }
  const name = String(riderName || "").trim();
  // Spaced numbers ("+234 803 123 4567") are how people actually
  // type phone numbers — strip the spaces before checking, so a
  // good number is not refused. The stored number has no spaces,
  // so it also passes the database's own phone check.
  const phone = String(riderPhone || "").trim().replace(/\s+/g, "");
  if (!name) {
    throw new Error("Enter the rider's name.");
  }
  if (name.length > 120) {
    throw new Error("Keep the rider's name under 120 characters.");
  }
  if (!phone) {
    throw new Error("Enter the rider's phone number.");
  }
  if (!/^\+?[0-9][0-9 ()-]{6,14}$/.test(phone)) {
    throw new Error("That rider phone number does not look right.");
  }
  const updated = await updateOrder(orderId, { rider_name: name, rider_phone: phone });
  notifyUser(order.buyer_id, {
    kind: "order",
    title: "Rider assigned",
    body: `The rider for order ${order.code} is ${name} — ${phone}.`,
    link: `/tracking/${order.id}`,
    orderId: order.id,
  });
  return { order: withoutDeliveryPin(updated) };
}

// ---------------------------------------------------------------------------
// Delivery PIN — buyer only. A wrong PIN throws and marks nothing.
// ---------------------------------------------------------------------------

export async function confirmDeliveryWithPin(orderId, pin, userId) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = userId ? { id: userId } : await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.buyer_id !== user.id) {
    throw new Error("Only the buyer can confirm delivery with the PIN.");
  }
  if (!order.delivery_pin) {
    throw new Error("This order has no delivery PIN yet — the seller has not submitted shipping proof.");
  }
  if (String(pin || "").trim() !== String(order.delivery_pin).trim()) {
    throw new Error("That PIN does not match. Check the PIN on this page and try again — nothing has been marked as delivered.");
  }
  return confirmDelivery(orderId, user.id);
}

// ---------------------------------------------------------------------------
// Returns — buyer opens, PulseMarket team resolves.
// ---------------------------------------------------------------------------

export async function openReturn(orderId, { reason, fault }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.buyer_id !== user.id) {
    throw new Error("Only the buyer can open a return for this order.");
  }
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  // (DB-2) Cash orders are paid face to face — there is no held
  // money to refund, so a return through the ledger can never
  // resolve. Sort it out with the seller directly.
  if (order.payment_method === "cash") {
    throw new Error("Cash orders are paid face to face — there is no held money to refund. Sort it out with the seller directly.");
  }
  // Morning deep check 2026-11-28: returns are a shipping flow —
  // the item has to travel back. A meetup order was handed over in
  // person, so there is nothing to ship back; sort it out with the
  // seller directly (or report a problem if it is wrong).
  if (order.delivery_method === "meetup") {
    throw new Error("Meet-in-person orders are handed over face to face — there is nothing to ship back. Sort it out with the seller directly, or report a problem if the item is wrong.");
  }
  if (!["shipped", "delivered"].includes(order.status)) {
    throw new Error(
      `This order is ${order.status} — a return can only be opened after the item has shipped.`
    );
  }
  if (order.return_status === "opened") {
    throw new Error("A return is already open for this order.");
  }
  if (!["seller", "buyer"].includes(fault)) {
    throw new Error("Say whose fault the return is: the seller's or yours.");
  }
  if (!reason || !RETURN_REASONS.includes(reason)) {
    throw new Error("Choose a reason for the return from the list.");
  }
  const updated = await updateOrder(orderId, {
    return_status: "opened",
    return_reason: `${fault === "seller" ? "Seller fault" : "Buyer fault"}: ${reason}`,
  });
  // Milestone 10: tell both parties a return is open.
  notifyUser(order.buyer_id, {
    kind: "dispute",
    title: "Return opened",
    body: `A return was opened for order ${order.code}: ${reason}.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  notifyUser(order.seller_id, {
    kind: "dispute",
    title: "Return opened",
    body: `A return was opened for order ${order.code}: ${reason}.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  return updated;
}

// Owner only. The `fault` decides who pays:
//   - Seller fault (wrong / damaged / not as described / fake): the
//     buyer gets the FULL total back — item price + shipping +
//     fees (Milestone 20 D-3: the buyer loses nothing when the
//     seller is at fault). The seller owes the shipping advance
//     back — it is recorded as a 'debt' ledger entry against the
//     seller until they settle it, and the seller pays the return
//     shipping.
//   - Buyer fault (changed mind): the buyer gets the item price back
//     only. The seller keeps the shipping advance, and the rest of the
//     shipping fee is released to the seller. The buyer pays the return
//     shipping.
export async function resolveReturn(orderId, { fault, attested = false }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  if (user.email !== OWNER_EMAIL) {
    throw new Error("Only the PulseMarket team can resolve a return.");
  }
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  // (DB-2) Cash orders never hold money, so there is no refund to
  // resolve through the ledger.
  if (order.payment_method === "cash") {
    throw new Error("Cash orders are paid face to face — there is no held money to refund.");
  }
  if (order.return_status !== "opened") {
    throw new Error("There is no open return for this order.");
  }
  if (!["seller", "buyer"].includes(fault)) {
    throw new Error("Resolve the return as seller fault or buyer fault.");
  }
  // The status check comes BEFORE the label correction below: a
  // resolve that cannot run must not leave the stored fault label
  // changed behind it.
  if (!["shipped", "delivered"].includes(order.status)) {
    throw new Error(
      `This order is ${order.status} — it can no longer be refunded this way.`
    );
  }
  // Morning deep check 2026-11-28: a return used to resolve (and
  // refund) with no proof the item ever came back — the buyer could
  // keep the item AND get the money. A refund needs either a
  // verified return photo from the buyer (kind 'return', recorded
  // in the app) or the team's own attestation that they saw the
  // item come back. This gate runs before the label correction and
  // before any money moves, so a refused resolve leaves nothing
  // changed behind it.
  if (!attested) {
    const { data: returnProof, error: proofError } = await supabase
      .from("evidence")
      .select("id")
      .eq("order_id", order.id)
      .eq("user_id", order.buyer_id)
      .eq("kind", "return")
      .eq("verified", true)
      .limit(1);
    if (proofError) throw proofError;
    if (!returnProof || returnProof.length === 0) {
      throw new Error(
        "No verified return photo for this order yet — ask the buyer to record one in the Evidence Locker (return photo), or tick that you have seen the item come back yourself."
      );
    }
  }
  // The refund legs are priced from the fault stored on the return
  // when it was opened ("Seller fault: ..." / "Buyer fault: ..."),
  // and the database refuses legs priced for the other fault.
  // Milestone 20 (§12-B, widened) lets the team correct a wrong
  // stored label while the return is still open — but the
  // correction MUST be its own update BEFORE the refund legs are
  // written, because the ledger prices the legs from the stored
  // reason at insert time, and the resolving update comes after
  // the legs. The detail text after the prefix is kept.
  // Night deep check 2026-11-27: the correction used to run BEFORE
  // the double-resolve guard below, so a retry with the wrong fault
  // permanently rewrote the stored label even though the money was
  // already priced for the original fault. It now runs after the
  // guard (see below, before the money moves).
  const storedFault = String(order.return_reason || "").startsWith("Seller fault")
    ? "seller"
    : String(order.return_reason || "").startsWith("Buyer fault")
      ? "buyer"
      : null;
  let labelCorrected = false;
  const correctFaultLabel = async () => {
    if (storedFault !== fault) {
      const detail = String(order.return_reason || "")
        .split(":")
        .slice(1)
        .join(":")
        .trim();
      const corrected =
        (fault === "seller" ? "Seller fault" : "Buyer fault") +
        (detail ? `: ${detail}` : "");
      await updateOrder(orderId, { return_reason: corrected });
      labelCorrected = true;
    }
  };

  const total = Number(order.total) || 0;
  const itemPrice = Number(order.item_price) || 0;
  const shippingFee = Number(order.shipping_fee) || 0;
  const advance = await advanceAlreadyReleased(order.id);
  // Double-resolve guard: the refund must move exactly once. The
  // database refuses a second refund pair too (unique indexes in
  // supabase/milestone-14.sql); this check gives the plain error.
  // BUT a refund row can exist while the order still says the return
  // is open — the money moved, then the status update never landed.
  // Throwing then would leave the order stuck for ever, so just close
  // it out instead of moving money again.
  if (supabase) {
    const { data: existingRefund } = await supabase
      .from("wallet_ledger")
      .select("id, note")
      .eq("order_id", order.id)
      .eq("kind", "refund")
      .eq("bucket", "held")
      .limit(1);
    if (existingRefund && existingRefund.length > 0) {
      if (order.status === "refunded" && order.return_status === "resolved") {
        throw new Error("This return was already resolved — the refund moved once.");
      }
      // (DB-16) If the first resolve wrote the refund but crashed
      // before recording the seller-fault debt, re-record it now —
      // otherwise the advance the seller kept is never owed back.
      // The fault that counts is the one the refund legs were
      // actually priced for — read it from the refund leg's note,
      // not from this call's `fault` argument: a retry with the
      // other fault would otherwise record a debt for a buyer-fault
      // refund (the seller legitimately kept the advance) or skip
      // the debt for a seller-fault one (the seller keeps money the
      // buyer was refunded in full).
      // ORDER MATTERS (milestone-21 §1): the debt must be recorded
      // BEFORE the order flips to refunded — the database refuses
      // a refunded order with an advance and no debt row. If the
      // debt write fails here, the flip below fails loudly with
      // the exact error instead of silently creating money.
      const refundNote = String(existingRefund[0]?.note || "");
      const refundWasSellerFault = /seller fault/i.test(refundNote)
        ? true
        : /buyer fault/i.test(refundNote)
          ? false
          : fault === "seller";
      // Morning deep check 2026-11-28: a held refund leg alone only
      // proves the FIRST leg exists. A half-written pair (held leg
      // only, buyer never paid) used to be closed out as a resolved
      // return here. Verify the buyer's available leg, for the right
      // amount for the fault the refund was actually priced for —
      // seller fault pays the full total, buyer fault pays the item
      // price only — before closing out. Otherwise say plainly that
      // the refund is only half recorded and the team must check it.
      const expectedRefund = refundWasSellerFault ? total : itemPrice;
      const refundPaid = await ledgerMoveAmount(order.id, "refund", "available");
      if (refundPaid === null || refundPaid !== expectedRefund) {
        throw new Error(
          "This refund is only half recorded — the buyer has not been paid back yet. Ask the PulseMarket team to check it."
        );
      }
      if (refundWasSellerFault && advance > 0) {
        const { data: existingDebt } = await supabase
          .from("wallet_ledger")
          .select("id")
          .eq("order_id", order.id)
          .eq("kind", "debt")
          .limit(1);
        if (!existingDebt || existingDebt.length === 0) {
          try {
            await recordSellerDebt(
              order.id,
              advance,
              `Shipping advance to pay back — seller-fault return, order ${order.code}. Recorded on recovery: the refund moved before the debt did.`
            );
          } catch (debtErr) {
            // Night deep check 2026-11-27: same as refundHeldOrder —
            // a failed debt write must surface its real cause
            // instead of being logged while the flip below fails
            // anyway on the M21 trigger (refunded order with an
            // advance and no debt). The 23505 duplicate means the
            // debt is already recorded.
            if (debtErr?.code !== "23505") throw debtErr;
          }
        }
      }
      const closed = await updateOrder(orderId, {
        status: "refunded",
        return_status: "resolved",
      });
      notifyUser(order.buyer_id, {
        kind: "dispute",
        title: "Return resolved",
        body: `The return for order ${order.code} was resolved.`,
        link: `/order/${order.id}`,
        orderId: order.id,
      });
      notifyUser(order.seller_id, {
        kind: "dispute",
        title: "Return resolved",
        body: `The return for order ${order.code} was resolved.`,
        link: `/order/${order.id}`,
        orderId: order.id,
      });
      // Milestone 20 (APP-14): same reactivation as the main path
      // below — the item comes back to the seller even when this
      // call only closes out an already-moved refund.
      try {
        await reactivateListingAfterRefund(order.listing_id);
      } catch (err) {
        console.error(
          "[PulseMarket] resolve return: could not put listing back to active:",
          err?.message || err
        );
      }
      return {
        order: closed,
        note: "This return was already resolved — the refund moved once, so this just closes the order out.",
      };
    }
  }
  // The label correction runs here, AFTER the double-resolve guard
  // above and BEFORE the refund legs below: a retry of an
  // already-moved refund never rewrites the stored fault label,
  // and a fresh resolve still corrects it before the legs are
  // priced from it.
  await correctFaultLabel();
  // Money still sitting in the seller's held bucket for this order:
  // the full total, minus any advance already released.
  const remainingHeld = Math.max(0, total - advance);
  let note;

  if (fault === "seller") {
    const moves = [
      {
        userId: order.seller_id,
        bucket: "held",
        kind: "refund",
        amount: -remainingHeld,
        note: `Refund — seller fault return, order ${order.code}`,
      },
      {
        userId: order.buyer_id,
        bucket: "available",
        kind: "refund",
        // Milestone 20 (D-3 / M-1): the buyer gets the FULL total
        // back, fees included — NOT item + shipping. The shipping
        // advance the seller already received is clawed back
        // separately as a seller debt below, so the books balance.
        amount: total,
        note: `Refund — seller fault return, order ${order.code}`,
      },
    ];
    try {
      await recordLedgerMove(order, moves);
    } catch (err) {
      if (err?.code === "23505") {
        throw new Error("This return was already resolved — the refund moved once.");
      }
      throw err;
    }
    if (advance > 0) {
      await recordSellerDebt(
        order.id,
        advance,
        `Shipping advance to pay back — seller-fault return, order ${order.code}. The buyer was refunded in full, so the advance the seller already received has to come back.`
      );
    }
    note =
      `Seller fault: the buyer gets ${total} naira back (the full total — item price + shipping + fees). ` +
      (labelCorrected
        ? `The return was opened under the other fault label, so the label was corrected to seller fault first. `
        : "") +
      (advance > 0
        ? `The seller owes the ${advance} naira shipping advance back — it is recorded as a debt on the seller's wallet until they settle it, and the seller pays the return shipping.`
        : `No shipping advance was ever released, so the seller owes nothing back. The seller pays the return shipping.`);
  } else {
    const moves = [
      {
        userId: order.seller_id,
        bucket: "held",
        kind: "refund",
        amount: -remainingHeld,
        note: `Refund — buyer fault return, order ${order.code}`,
      },
      {
        userId: order.buyer_id,
        bucket: "available",
        kind: "refund",
        amount: itemPrice,
        note: `Refund — buyer fault return, order ${order.code}`,
      },
    ];
    const remainingShipping = Math.max(0, shippingFee - advance);
    if (remainingShipping > 0) {
      moves.push({
        userId: order.seller_id,
        bucket: "available",
        kind: "release",
        amount: remainingShipping,
        note: `Remaining shipping fee — buyer fault return, order ${order.code}`,
      });
    }
    try {
      await recordLedgerMove(order, moves);
    } catch (err) {
      if (err?.code === "23505") {
        throw new Error("This return was already resolved — the refund moved once.");
      }
      throw err;
    }
    note =
      `Buyer fault: the buyer gets the item price back only (${itemPrice} naira). ` +
      (labelCorrected
        ? `The return was opened under the other fault label, so the label was corrected to buyer fault first. `
        : "") +
      `The seller keeps the shipping advance${advance > 0 ? ` (${advance} naira)` : ""} and the rest of the shipping fee, and the buyer pays the return shipping.`;
  }

  // Record how the return was proven, so the team can audit it
  // later: a verified return photo, or the team's own attestation.
  if (attested) {
    note += " The team confirmed the item came back in person (no return photo on file).";
  }

  const updated = await updateOrder(orderId, {
    status: "refunded",
    return_status: "resolved",
  });
  // Milestone 20 (APP-14): the item comes back to the seller, so
  // the listing goes back to 'active' — a refunded listing used to
  // stay reserved/sold and could never be listed again. Best
  // effort: the refund already moved, so a failed reactivation is
  // logged, never thrown. Amounts above match the Milestone 20
  // SQL (D-3/M-1): seller fault pays the buyer the full total,
  // the advance is clawed back as a seller debt.
  try {
    await reactivateListingAfterRefund(order.listing_id);
  } catch (err) {
    console.error(
      "[PulseMarket] resolve return: could not put listing back to active:",
      err?.message || err
    );
  }
  // Milestone 10: tell both parties the return is resolved.
  notifyUser(order.buyer_id, {
    kind: "dispute",
    title: "Return resolved",
    body: `The return for order ${order.code} was resolved (${fault} fault).`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  notifyUser(order.seller_id, {
    kind: "dispute",
    title: "Return resolved",
    body: `The return for order ${order.code} was resolved (${fault} fault).`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  return { order: updated, note };
}

// Morning deep check 2026-11-28 (SQL review M2): an opened return
// had NO "reject" exit — a bogus return (buyer changed their mind
// after opening it, or the claim does not hold up) could only be
// resolved with a refund, or left open forever with the money
// frozen. Rejecting is terminal: the order carries on as if the
// return never happened (release and the 48h auto-release are
// unblocked again), and the buyer's recourse if something is still
// wrong is a dispute. No money moves here.
// NOTE: the database transition opened -> rejected is added by
// supabase/milestone-24.sql — until that file has been run, the
// trigger refuses this update and the team sees its plain error.
export async function rejectReturn(orderId) {
  if (!supabase) throw new Error("Supabase is not configured.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first.");
  if (user.email !== OWNER_EMAIL) {
    throw new Error("Only the PulseMarket team can reject a return.");
  }
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  if (order.return_status !== "opened") {
    throw new Error("There is no open return for this order.");
  }
  const updated = await updateOrder(orderId, {
    return_status: "rejected",
  });
  notifyUser(order.buyer_id, {
    kind: "dispute",
    title: "Return rejected",
    body: `The return for order ${order.code} was rejected — the order carries on as normal. If something is still wrong with the item, report a problem from the order page.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  notifyUser(order.seller_id, {
    kind: "dispute",
    title: "Return rejected",
    body: `The return for order ${order.code} was rejected — the order carries on as normal.`,
    link: `/order/${order.id}`,
    orderId: order.id,
  });
  return {
    order: updated,
    note: "Return rejected — the order carries on as normal. The buyer can still report a problem if something is wrong.",
  };
}

// Listing reactivation after a refund (APP-14). A status-only
// update through the listings table: no ownership check applies to
// a status move, and the listing-status trigger allows
// reserved -> active, so the team (the only caller of
// resolveReturn) can put the item back on sale.
async function reactivateListingAfterRefund(listingId) {
  if (!supabase || !listingId) return;
  const { error } = await supabase
    .from("listings")
    .update({ status: "active" })
    .eq("id", listingId);
  if (error) throw error;
}

// Record that a seller owes money back (a negative 'available' entry).
// Used by resolveReturn for a seller-fault return, and by the team when
// a seller owes return shipping + advance and does not settle. The
// coordinator wires the "cannot list / cannot withdraw until cleared"
// gates — this helper only records the debt.
export async function recordSellerDebt(orderId, amount, note) {
  if (!supabase) throw new Error("Supabase is not configured.");
  // Only the PulseMarket team records a seller debt. Without this
  // check any order participant could call this helper directly and
  // write an arbitrary debt against the seller — the database only
  // checks that the debt belongs to the seller and is negative.
  const user = await currentUser();
  if (!user || user.email !== OWNER_EMAIL) {
    throw new Error("Only the PulseMarket team can record a seller debt.");
  }
  const order = await readOrder(orderId);
  if (!order) throw new Error("Order not found.");
  const owed = Math.max(0, Math.round(Number(amount) || 0));
  if (owed <= 0) return null;
  // Milestone 20 (APP-17): one debt per order — return the existing
  // debt row when one is already recorded for this order, instead of
  // inserting a second one. The unique index in the Milestone 20 SQL
  // is the backstop; this is the app-side check, and the 23505 catch
  // below covers a debt recorded between the check and the insert
  // (double-tap / retry from another device).
  const { data: existingDebt } = await supabase
    .from("wallet_ledger")
    .select("*")
    .eq("order_id", order.id)
    .eq("kind", "debt")
    .limit(1)
    .maybeSingle();
  if (existingDebt) return existingDebt;
  const { data, error } = await supabase
    .from("wallet_ledger")
    .insert({
      order_id: order.id,
      user_id: order.seller_id,
      bucket: "available",
      kind: "debt",
      amount: -owed,
      note: note || `Seller debt for order ${order.code}`,
      // Milestone 22: the team records the debt, so the team is the
      // actor — the old code blamed the buyer (see recordLedgerMove).
      created_by: user.id,
    })
    .select()
    .single();
  if (error) {
    if (error.code === "23505") {
      const { data: raced } = await supabase
        .from("wallet_ledger")
        .select("*")
        .eq("order_id", order.id)
        .eq("kind", "debt")
        .limit(1)
        .maybeSingle();
      if (raced) return raced;
    }
    throw error;
  }
  return data;
}

// True when the seller still owes money (unsettled 'debt' entries,
// minus any 'repayment' entries). The coordinator gates listing and
// withdrawals on this.
export async function hasSellerDebt(sellerId) {
  return (await sellerDebtAmount(sellerId)) > 0;
}

export async function sellerDebtAmount(sellerId) {
  if (!supabase || !sellerId) return 0;
  // Morning deep check 2026-11-28: the old read had no limit, so
  // PostgREST silently stopped at its 1000-row default and a
  // seller's debt was undercounted past 1000 rows. Page through
  // every debt/repayment row (same pattern as getBalances).
  let owed = 0;
  const PAGE = 1000;
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from("wallet_ledger")
      .select("kind, amount")
      .eq("user_id", sellerId)
      .in("kind", ["debt", "repayment"])
      .range(from, from + PAGE - 1);
    if (error) {
      dbError(error, "read seller debt");
      return 0;
    }
    for (const row of data || []) {
      if (row.kind === "debt") owed += Math.abs(Number(row.amount) || 0);
      if (row.kind === "repayment") owed -= Number(row.amount) || 0;
    }
    if (!data || data.length < PAGE) break;
  }
  return Math.max(0, owed);
}

// Debt gate — WIRED since Milestone 19 (the old "ready to wire,
// not yet wired" comment was stale). Call sites:
//   1. Sell.jsx, before createListingRow(): a seller who still owes
//      money from an earlier order must not list a new item until
//      the team settles the debt.
//      `await assertSellerClearOfDebt(user.id);`
//   2. The manual withdrawal step (Wallet.jsx): withdrawals are paid
//      by hand by the team, so there is no in-app withdraw function
//      to gate — the team checks sellerDebtAmount() (Admin.jsx debt
//      check) before paying any withdrawal, and holds the payout
//      while debt is outstanding.
//   The wallet math already nets debt: a debt row is a negative
//   'available' entry, so getBalances() already subtracts what is
//   owed — a seller cannot withdraw more than the net available
//   balance. What the gate adds is stopping NEW earnings while a
//   debt is unpaid, not fixing a double-spend.
export async function sellerDebtGate(sellerId) {
  const amount = await sellerDebtAmount(sellerId);
  return { hasDebt: amount > 0, amount };
}

export async function assertSellerClearOfDebt(sellerId) {
  const { hasDebt, amount } = await sellerDebtGate(sellerId);
  if (hasDebt) {
    throw new Error(
      `You owe ${amount.toLocaleString("en-NG")} naira back to PulseMarket from an earlier order — settle it with the PulseMarket team first, then list again.`
    );
  }
  return true;
}
