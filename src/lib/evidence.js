// Milestone 9 — Evidence Locker: in-app camera media only, verified
// ticks, money gates. Every read function returns null / [] and logs
// the error when the tables do not exist yet (owner has not run
// supabase/milestone-9.sql), so the app says so honestly instead of
// crashing. Write functions throw a clear Error when the caller is not
// allowed or the media fails its rule.
//
// Media model:
//   - Videos are recorded IN THE APP with MediaRecorder (recordVideo
//     below). Photos come from the camera capture input on the page.
//     Nothing is picked from the gallery, so a video cannot be faked
//     by uploading an old clip.
//   - A row is verified ONLY when it passes its kind's duration rule
//     (see EVIDENCE_RULES). Anything else is stored with verified=false
//     and a plain verified_reason, so the student can see exactly why
//     it did not count.
//   - The verified tick is what gates money: confirmDelivery in
//     orders.js refuses a shipping order until the buyer has a verified
//     unboxing video for it.
import { useEffect, useState } from "react";
import { supabase } from "./supabase";
import { assertRealPhoto } from "./shipping";

export const EVIDENCE_BUCKET = "evidence-media";

export const EVIDENCE_KINDS = [
  "packing",
  "unboxing",
  "dispute",
  "handoff",
  "waybill",
  "receipt",
  "return",
];

// Duration rules, in seconds. Video kinds must be videos of the given
// length; photo kinds must be photos and have no duration rule.
export const EVIDENCE_RULES = {
  dispute: {
    mediaType: "video",
    minSeconds: 10,
    maxSeconds: 20,
    label: "Dispute evidence",
    ruleText: "Video, 10–20 seconds. Record it in the app — show the problem clearly.",
  },
  packing: {
    mediaType: "video",
    minSeconds: 15,
    maxSeconds: 30,
    label: "Packing video",
    ruleText: "Video, 15–30 seconds. Record it in the app — show the item going into the parcel.",
  },
  unboxing: {
    mediaType: "video",
    minSeconds: 0,
    maxSeconds: 60,
    label: "Unboxing video",
    ruleText: "Video, no longer than 60 seconds. Record it in the app as you open the parcel.",
  },
  handoff: {
    mediaType: "photo",
    label: "Handoff photo",
    ruleText: "Photo, taken in the app at handover.",
  },
  waybill: {
    mediaType: "photo",
    label: "Waybill photo",
    ruleText: "Photo, taken in the app — the paper waybill, all four corners visible.",
  },
  receipt: {
    mediaType: "photo",
    label: "Receipt photo",
    ruleText: "Photo, taken in the app — the courier receipt.",
  },
  return: {
    mediaType: "photo",
    label: "Return photo",
    ruleText: "Photo, taken in the app — show the item being returned.",
  },
};

export function evidenceRule(kind) {
  return EVIDENCE_RULES[kind] || null;
}

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

async function currentUser() {
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getUser();
  if (error) {
    dbError(error, "get current user");
    return null;
  }
  return data?.user || null;
}

// ---------------------------------------------------------------------------
// Verification — pure function, same rules the upload path and the
// delivery gate use. Returns { verified, verified_reason }.
// `row` is an evidence row (or anything with kind / media_type /
// duration_seconds). verified_reason is null when verified.
// ---------------------------------------------------------------------------

export function verifyEvidenceRow(row) {
  if (!row || !row.kind) {
    return { verified: false, verified_reason: "Missing evidence details." };
  }
  const rule = EVIDENCE_RULES[row.kind];
  if (!rule) {
    return { verified: false, verified_reason: `Unknown evidence kind: ${row.kind}.` };
  }
  const label = rule.label;
  if (rule.mediaType === "photo") {
    if (row.media_type !== "photo") {
      return {
        verified: false,
        verified_reason: `${label} must be a photo, not a video.`,
      };
    }
    return { verified: true, verified_reason: null };
  }
  // Video kinds.
  if (row.media_type !== "video") {
    return {
      verified: false,
      verified_reason: `${label} must be a video — record it in the app.`,
    };
  }
  const seconds = row.duration_seconds;
  if (seconds === null || seconds === undefined || Number.isNaN(Number(seconds))) {
    return {
      verified: false,
      verified_reason: `Could not measure the video length — ${label.toLowerCase()} must be ${rule.minSeconds > 0 ? `${rule.minSeconds}–${rule.maxSeconds}` : `no longer than ${rule.maxSeconds}`} seconds.`,
    };
  }
  const s = Math.floor(Number(seconds));
  if (rule.minSeconds > 0 && s < rule.minSeconds) {
    return {
      verified: false,
      verified_reason: `Video is ${s}s — ${label.toLowerCase()} must be ${rule.minSeconds}–${rule.maxSeconds}s.`,
    };
  }
  if (s > rule.maxSeconds) {
    return {
      verified: false,
      verified_reason: `Video is ${s}s — ${label.toLowerCase()} must be ${rule.minSeconds > 0 ? `${rule.minSeconds}–${rule.maxSeconds}s` : `no longer than ${rule.maxSeconds} seconds`}.`,
    };
  }
  if (s <= 0) {
    return {
      verified: false,
      verified_reason: `Video is ${s}s — ${label.toLowerCase()} must be longer than 0 seconds.`,
    };
  }
  return { verified: true, verified_reason: null };
}

// ---------------------------------------------------------------------------
// In-app video capture — MediaRecorder.
// ---------------------------------------------------------------------------
//
// recordVideo({ onData, onTick, maxSeconds }) starts the camera and
// records until the caller stops it or maxSeconds is reached, then
// resolves to { blob, durationSeconds, mimeType }.
//
//   - onData(stream): called with the live MediaStream as soon as the
//     camera opens, so the page can show it in a <video> preview.
//   - onTick(seconds): called once a second with the elapsed whole
//     seconds, so the page can show a live duration while recording.
//   - The returned promise also carries a .stop() method: call it from
//     a Stop button to finish early. Recording stops automatically at
//     maxSeconds.
//   - Camera denial / no camera / no MediaRecorder throws a clear
//     Error: "Camera not available — allow camera access or use the
//     photo option".
//
// NOTE: real camera capture cannot be tested in a headless VM — there
// is no camera there. This helper follows the standard MediaRecorder
// flow (getUserMedia -> MediaRecorder -> chunks -> Blob) and fails
// cleanly when the camera is missing, but it has only been checked by
// build + code review, not by a real recording on a phone.

function pickMimeType() {
  if (typeof MediaRecorder === "undefined") return "";
  const candidates = [
    "video/webm;codecs=vp9,opus",
    "video/webm;codecs=vp8,opus",
    "video/webm",
    "video/mp4",
  ];
  for (const type of candidates) {
    try {
      if (MediaRecorder.isTypeSupported(type)) return type;
    } catch {
      // Ignore — try the next candidate.
    }
  }
  return "";
}

export function recordVideo({ onData, onTick, maxSeconds } = {}) {
  const max = Math.max(1, Math.round(Number(maxSeconds) || 60));
  let stream = null;
  let recorder = null;
  let timer = null;
  let stopped = false;
  // The clock starts when the recording itself starts, not when the
  // camera is asked for: the permission dialog can sit open for
  // seconds, and counting that time made a short clip look long
  // enough to pass (or a good clip look too long) before the real
  // length was measured.
  let startedAt = null;
  // Stop pressed while the camera permission dialog is still open:
  // there is no recorder yet to stop, so remember the request and
  // act on it as soon as the camera opens instead of recording to
  // the maximum with no way out.
  let stopRequested = false;
  const chunks = [];

  function elapsedSeconds() {
    if (!startedAt) return 0;
    return Math.floor((Date.now() - startedAt) / 1000);
  }

  function cleanup() {
    if (timer) {
      clearInterval(timer);
      timer = null;
    }
    if (stream) {
      stream.getTracks().forEach((t) => {
        try {
          t.stop();
        } catch {
          // Track already stopped — ignore.
        }
      });
      stream = null;
    }
  }

  function finish(resolve) {
    if (stopped) return;
    stopped = true;
    cleanup();
    const mimeType = recorder?.mimeType || pickMimeType() || "video/webm";
    const blob = new Blob(chunks, { type: mimeType });
    resolve({
      blob,
      durationSeconds: Math.max(1, elapsedSeconds()),
      mimeType,
    });
  }

  const promise = (async () => {
    if (
      typeof navigator === "undefined" ||
      !navigator.mediaDevices?.getUserMedia ||
      typeof MediaRecorder === "undefined"
    ) {
      throw new Error(
        "Camera not available — allow camera access or use the photo option."
      );
    }
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        video: true,
        audio: true,
      });
    } catch {
      throw new Error(
        "Camera not available — allow camera access or use the photo option."
      );
    }
    if (stopRequested) {
      cleanup();
      throw new Error("Recording stopped before it started.");
    }
    if (onData) onData(stream);
    const mimeType = pickMimeType();
    try {
      recorder = new MediaRecorder(stream, mimeType ? { mimeType } : undefined);
    } catch {
      cleanup();
      throw new Error(
        "Camera not available — allow camera access or use the photo option."
      );
    }
    recorder.ondataavailable = (event) => {
      if (event.data && event.data.size > 0) chunks.push(event.data);
    };
    // Auto-stop at the kind's max length.
    timer = setInterval(() => {
      const seconds = elapsedSeconds();
      if (onTick) onTick(seconds);
      if (seconds >= max && recorder && recorder.state !== "inactive") {
        recorder.stop();
      }
    }, 1000);
    const done = new Promise((resolve) => {
      recorder.onstop = () => finish(resolve);
    });
    startedAt = Date.now();
    recorder.start(250);
    return done;
  })();

  // Stop early from a Stop button: .stop() ends the recording and the
  // promise resolves with the clip recorded so far.
  promise.stop = () => {
    stopRequested = true;
    if (recorder && recorder.state !== "inactive") {
      try {
        recorder.stop();
      } catch {
        // Already stopping — the onstop handler still resolves.
      }
    }
  };
  // Expose the live stream so the page can detach it if it unmounts.
  promise.stream = () => stream;
  return promise;
}

// ---------------------------------------------------------------------------
// Upload + read + delete
// ---------------------------------------------------------------------------

function extensionFor(fileOrBlob, mediaType) {
  if (mediaType === "photo") return "jpg";
  const name = fileOrBlob?.name || "";
  const fromName = name.split(".").pop()?.toLowerCase();
  if (fromName === "mp4") return "mp4";
  const type = String(fileOrBlob?.type || "");
  if (type.includes("mp4")) return "mp4";
  return "webm";
}

function contentTypeFor(ext, mediaType) {
  if (mediaType === "photo") return "image/jpeg";
  return ext === "mp4" ? "video/mp4" : "video/webm";
}

async function toBlob(fileOrBlob) {
  if (typeof fileOrBlob === "string") {
    const res = await fetch(fileOrBlob);
    return res.blob();
  }
  return fileOrBlob;
}

// Measure a video blob's real length from the file itself, instead of
// trusting the duration the caller claims. Before this fix the
// duration came from recordVideo's wall-clock timer (or from any
// number a caller passed to uploadEvidence), so a 1-second clip — or
// a photo renamed .webm — could be uploaded claiming 15 seconds and
// earn a verified packing tick, and the database trigger recomputes
// verified from that same claimed number, so it could not catch it
// either. The measured length wins whenever the browser can read it;
// when it cannot (unplayable file, timeout) the caller's number is
// used as before and the row is still judged by the same rules.
async function measureVideoDuration(blob) {
  if (typeof document === "undefined" || !blob) return null;
  const url = URL.createObjectURL(blob);
  try {
    return await new Promise((resolve) => {
      let settled = false;
      const done = (value) => {
        if (settled) return;
        settled = true;
        resolve(value);
      };
      const timer = setTimeout(() => done(null), 5000);
      const video = document.createElement("video");
      video.preload = "metadata";
      video.muted = true;
      video.onerror = () => {
        clearTimeout(timer);
        done(null);
      };
      video.onloadedmetadata = () => {
        const d = video.duration;
        if (Number.isFinite(d) && d > 0) {
          clearTimeout(timer);
          // Floor, never round up: a 9.6s clip must not round up to a
          // passing 10s, and a 14.9s clip must not pass a 15s minimum.
          // (A clip up to ~1s over a maximum can still floor inside
          // it — the recorder auto-stops at the maximum, so the
          // overshoot is bounded there.)
          done(Math.floor(d));
          return;
        }
        // MediaRecorder webm files often report Infinity until the
        // player seeks: jump to the end and read the real duration.
        if (d === Infinity) {
          // MediaRecorder webm files often report Infinity until the
          // player seeks. Only settle once the duration is a real
          // number: the seek / duration events can fire while the
          // duration is still Infinity, and settling then refused a
          // good clip as "could not be measured".
          const onSeek = () => {
            if (Number.isFinite(video.duration) && video.duration > 0) {
              clearTimeout(timer);
              done(Math.floor(video.duration));
            }
            // Otherwise wait for the next event — the 5s timeout
            // above still settles this as unmeasurable if it never
            // resolves.
          };
          video.onseeked = onSeek;
          video.ondurationchange = onSeek;
          try {
            video.currentTime = Number.MAX_SAFE_INTEGER;
          } catch {
            done(null);
          }
          return;
        }
        clearTimeout(timer);
        done(null);
      };
      video.src = url;
    });
  } finally {
    URL.revokeObjectURL(url);
  }
}

// Uploads the file to the evidence-media bucket at
// <user-id>/evidence-<orderId>-<kind>-<timestamp>.<ext>, inserts the
// evidence row, and sets verified=true ONLY when the media passes its
// rule (video duration inside the kind's range, or a photo kind with a
// file present). Otherwise verified=false with a plain verified_reason.
// A video's duration is measured from the file itself, never taken
// from the caller — a clip that cannot be measured is refused, not
// stored with a claimed length.
export async function uploadEvidence(orderId, { kind, mediaType, fileOrBlob }) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!orderId) throw new Error("Missing order.");
  const rule = EVIDENCE_RULES[kind];
  if (!rule) throw new Error("Choose what kind of evidence this is.");
  if (mediaType !== rule.mediaType) {
    throw new Error(
      rule.mediaType === "video"
        ? `${rule.label} must be a video — record it in the app.`
        : `${rule.label} must be a photo — take it in the app.`
    );
  }
  if (!fileOrBlob) {
    throw new Error(
      mediaType === "video" ? "Record a video first." : "Take a photo first."
    );
  }
  const user = await currentUser();
  if (!user) throw new Error("Sign in first to upload evidence.");
  const { data: order, error: orderError } = await supabase
    .from("orders")
    .select("id, buyer_id, seller_id, frozen")
    .eq("id", orderId)
    .maybeSingle();
  if (orderError) throw orderError;
  if (!order) throw new Error("Order not found.");
  if (order.buyer_id !== user.id && order.seller_id !== user.id) {
    throw new Error("Only the buyer or seller of this order can add evidence for it.");
  }
  // Morning deep check 2026-11-28: no evidence may change while a
  // dispute is open — the evidence is part of what the team is
  // reviewing. Handoff photos already refuse when frozen; Evidence
  // Locker uploads did not.
  if (order.frozen) {
    throw new Error("This order is frozen — a dispute is open. The PulseMarket team resolves it first.");
  }
  // Who may record what: the buyer records the unboxing, dispute
  // and return videos; the seller records the packing video and the
  // shipping photos. Either side could upload any kind before, so a
  // seller's "unboxing" clip satisfied the buyer's delivery gate
  // (the gates in orders.js / disputes.js now check the recorder
  // too — this is the backstop at the source). Handoff photos go
  // through handoff.js, not here, so that kind stays open to both.
  const BUYER_KINDS = ["unboxing", "dispute", "return"];
  const SELLER_KINDS = ["packing", "waybill", "receipt"];
  if (BUYER_KINDS.includes(kind) && order.buyer_id !== user.id) {
    throw new Error("Only the buyer can record this evidence.");
  }
  if (SELLER_KINDS.includes(kind) && order.seller_id !== user.id) {
    throw new Error("Only the seller can record this evidence.");
  }

  const blob = await toBlob(fileOrBlob);
  // A giant file stalls the upload and the storage bill — refuse it
  // plainly instead of uploading for minutes and failing.
  if (blob && blob.size > (mediaType === "photo" ? 10 : 100) * 1024 * 1024) {
    throw new Error(
      mediaType === "photo"
        ? "That photo is too big — keep evidence photos under 10MB."
        : "That video is too big — keep evidence videos under 100MB."
    );
  }
  // Milestone 20 (APP-11): a file with NO MIME type at all is
  // refused, not skipped past the check — an empty blob.type used
  // to bypass the photo/video check entirely, so anything could be
  // stored as "evidence".
  if (!blob || !blob.type) {
    throw new Error(
      "Could not tell what kind of file this is — take the photo or record the video again in the app."
    );
  }
  // The file must be what the kind claims it is — a photo renamed
  // .webm (or a video file passed as a photo) never counts, whatever
  // its name or extension says.
  if (mediaType === "photo" && !blob.type.startsWith("image/")) {
    throw new Error("That file is not a photo — take a photo in the app.");
  }
  if (mediaType === "video" && !blob.type.startsWith("video/")) {
    throw new Error("That file is not a video — record a video in the app.");
  }
  // Milestone 20 (APP-11): a photo must also pass the magic-byte
  // check — a renamed document with an image MIME type used to sail
  // through on the prefix alone. Same check as the waybill photos.
  if (mediaType === "photo") {
    await assertRealPhoto(blob, kind);
  }
  // Video length is measured from the file itself (see
  // measureVideoDuration) and NOTHING else counts. When the file
  // cannot be measured at all — an unplayable file, a photo renamed
  // .webm, a corrupt clip — the upload is refused outright. The old
  // code fell back to the duration the caller claimed in that case,
  // so a 1-second clip (or a photo renamed .webm) claiming 15
  // seconds earned a verified packing tick, and the database trigger
  // recomputes verified from that same claimed number, so it could
  // not catch it either. A money gate must fail closed, never on a
  // claim.
  const measuredDuration =
    mediaType === "video" ? await measureVideoDuration(blob) : null;
  if (mediaType === "video" && measuredDuration === null) {
    throw new Error(
      "Could not measure this video's length — record it again in the app."
    );
  }
  const ext = extensionFor(fileOrBlob, mediaType);
  const path = `${user.id}/evidence-${orderId}-${kind}-${Date.now()}.${ext}`;
  const { error: uploadError } = await supabase.storage
    .from(EVIDENCE_BUCKET)
    .upload(path, blob, { contentType: contentTypeFor(ext, mediaType), upsert: false });
  if (uploadError) throw uploadError;
  const { data: urlData } = supabase.storage
    .from(EVIDENCE_BUCKET)
    .getPublicUrl(path);

  const check = verifyEvidenceRow({
    kind,
    media_type: mediaType,
    duration_seconds: mediaType === "video" ? measuredDuration : null,
  });
  const { data, error } = await supabase
    .from("evidence")
    .insert({
      order_id: orderId,
      user_id: user.id,
      kind,
      media_type: mediaType,
      url: urlData.publicUrl,
      duration_seconds: mediaType === "video" ? measuredDuration : null,
      verified: check.verified,
      verified_reason: check.verified_reason,
    })
    .select()
    .single();
  if (error) {
    // The file is already in the bucket; remove it so a failed row
    // does not leave an orphan file behind.
    await supabase.storage.from(EVIDENCE_BUCKET).remove([path]);
    throw error;
  }
  return data;
}

export async function fetchEvidenceForOrder(orderId) {
  if (!supabase || !orderId) return [];
  const { data, error } = await supabase
    .from("evidence")
    .select("*")
    .eq("order_id", orderId)
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) {
    dbError(error, "fetch evidence for order");
    return [];
  }
  return data || [];
}

// Morning deep check 2026-11-28: same read as
// fetchEvidenceForOrder, but the caller can tell a failed read
// apart from "no evidence". That matters for the delivery gate in
// OrderDetail: the old function returned [] on ANY error, so a
// failed read looked exactly like "no verified unboxing video" and
// the buyer was stuck with a disabled button, no error and no retry.
export async function fetchEvidenceForOrderChecked(orderId) {
  if (!supabase || !orderId) return { rows: [], failed: true };
  const { data, error } = await supabase
    .from("evidence")
    .select("*")
    .eq("order_id", orderId)
    .order("created_at", { ascending: false })
    .limit(100);
  if (error) {
    dbError(error, "fetch evidence for order");
    return { rows: [], failed: true };
  }
  return { rows: data || [], failed: false };
}

// All evidence across the user's orders, newest first. Paged the
// same way as fetchMyOrders: without a `before` cursor a student
// with more than 100 evidence rows silently lost the older ones
// (their order sections said "No evidence for this order yet"
// even though the recordings existed).
export async function fetchMyEvidence(userId, { before } = {}) {
  if (!supabase || !userId) return [];
  let query = supabase
    .from("evidence")
    .select("*")
    .eq("user_id", userId)
    .order("created_at", { ascending: false });
  if (before) query = query.lt("created_at", before);
  const { data, error } = await query.limit(100);
  if (error) {
    dbError(error, "fetch my evidence");
    return [];
  }
  const rows = data || [];
  rows.hasMore = rows.length === 100;
  return rows;
}

// Owner of the row only. Also deletes the storage object, so no orphan
// file is left in the evidence-media bucket.
export async function deleteEvidence(id) {
  if (!supabase) throw new Error("Supabase is not configured.");
  if (!id) throw new Error("Missing evidence.");
  const user = await currentUser();
  if (!user) throw new Error("Sign in first to delete evidence.");
  const { data: row, error: readError } = await supabase
    .from("evidence")
    .select("*")
    .eq("id", id)
    .maybeSingle();
  if (readError) throw readError;
  if (!row) throw new Error("Evidence not found.");
  if (row.user_id !== user.id) {
    throw new Error("Only the student who recorded this can delete it.");
  }
  // Milestone 22: evidence that a live case depends on cannot be
  // deleted. A buyer used to be able to file a dispute — which
  // needs a verified dispute video and freezes the money — and then
  // delete that video, leaving the team with a frozen order and no
  // proof. Refuse while the order is frozen, while a return is open,
  // or while a dispute video backs an open report. (Deleting an
  // unboxing video after delivery stays allowed: the delivery gate
  // re-checks it at confirm time, so it cannot be used to undo a
  // delivery.)
  if (row.order_id) {
    const { data: order, error: orderError } = await supabase
      .from("orders")
      .select("id, frozen, return_status")
      .eq("id", row.order_id)
      .maybeSingle();
    if (orderError) {
      throw new Error("Could not check this order — try again.");
    }
    if (order?.frozen) {
      throw new Error("This order has an open dispute — its evidence stays until the team resolves it.");
    }
    if (order?.return_status === "opened") {
      throw new Error("This order has an open return — its evidence stays until the return is resolved.");
    }
    if (row.kind === "dispute") {
      const { data: openDispute, error: disputeError } = await supabase
        .from("disputes")
        .select("id")
        .eq("order_id", row.order_id)
        .in("status", ["open", "under_review"])
        .limit(1)
        .maybeSingle();
      if (disputeError) {
        throw new Error("Could not check this order — try again.");
      }
      if (openDispute) {
        throw new Error("This video backs an open dispute — it stays until the team resolves it.");
      }
    }
  }
  // Delete the ROW first, then the file. The old order deleted the
  // file first — if the row delete then failed, the row survived
  // pointing at a deleted file. An orphaned file is harmless; a
  // dangling pointer is not. A failed file delete is only logged.
  const { error } = await supabase.from("evidence").delete().eq("id", id);
  if (error) throw error;
  const path = storagePathFromUrl(row.url);
  if (path) {
    const { error: storageError } = await supabase.storage
      .from(EVIDENCE_BUCKET)
      .remove([path]);
    if (storageError) {
      dbError(storageError, "delete evidence file");
    }
  }
  return true;
}

// Public bucket URLs look like
// .../storage/v1/object/public/evidence-media/<user-id>/evidence-....jpg
// — the part after the bucket name is the storage path. Signed URLs
// look like .../object/sign/evidence-media/<path>?token=... — the
// path is the part after the bucket name, before the query. A bare
// path (no URL at all) is returned as-is, so callers that already
// hold a path can use the same helper.
export function storagePathFromUrl(url) {
  if (!url) return null;
  const str = String(url);
  for (const marker of [
    `/object/public/${EVIDENCE_BUCKET}/`,
    `/object/sign/${EVIDENCE_BUCKET}/`,
  ]) {
    const idx = str.indexOf(marker);
    if (idx !== -1) {
      const rest = str.slice(idx + marker.length).split("?")[0];
      return rest || null;
    }
  }
  if (!str.includes("://") && str.includes("/")) return str;
  return null;
}

// ---------------------------------------------------------------------------
// Signed URLs (Milestone 20, M-6) — mirror of verificationIdPhotoUrl
// in listings.js: the evidence-media bucket goes private in the
// Milestone 20 SQL, so public URLs stop working and every render of
// an evidence / handoff / waybill / receipt / checkpoint photo must
// mint a short-lived signed URL instead. Signed URLs also work while
// the bucket is still public, so this is safe to ship before the SQL
// runs. Links live for 1 hour and are re-minted when older than
// ~50 minutes; a mint failure falls back to the stored URL, which
// still works until the bucket goes private.
// ---------------------------------------------------------------------------

const signedUrlCache = new Map(); // path -> { url, mintedAt }

export async function evidenceSignedUrl(storedUrl) {
  if (!supabase || !storedUrl) return storedUrl || null;
  const path = storagePathFromUrl(storedUrl);
  if (!path) return storedUrl;
  const cached = signedUrlCache.get(path);
  if (cached && Date.now() - cached.mintedAt < 50 * 60 * 1000) {
    return cached.url;
  }
  try {
    const { data, error } = await supabase.storage
      .from(EVIDENCE_BUCKET)
      .createSignedUrl(path, 3600);
    if (error) throw error;
    const url = data?.signedUrl || null;
    if (url) signedUrlCache.set(path, { url, mintedAt: Date.now() });
    return url || storedUrl;
  } catch (err) {
    dbError(err, "mint evidence signed URL");
    return storedUrl;
  }
}

// Mint signed URLs for a list of stored URLs at once. Returns a Map
// (stored URL -> signed URL, or the stored URL when minting failed).
export async function resolveEvidenceUrls(urls) {
  const out = new Map();
  const list = [...new Set((urls || []).filter(Boolean))];
  await Promise.all(
    list.map(async (url) => {
      out.set(url, (await evidenceSignedUrl(url)) || url);
    })
  );
  return out;
}

// React hook for pages that render stored evidence-media URLs: pass
// the URLs on screen and get back a Map (stored URL -> signed URL).
// URLs with no signed URL yet (still minting, or minting failed)
// fall back to the stored URL, so the page never shows a broken
// image while the bucket is still public.
export function useSignedEvidenceUrls(urls) {
  const [map, setMap] = useState(new Map());
  const key = (urls || []).join("|");
  useEffect(() => {
    let alive = true;
    const list = [...new Set((urls || []).filter(Boolean))];
    if (list.length === 0) return;
    resolveEvidenceUrls(list).then((m) => {
      if (alive) setMap(m);
    });
    return () => {
      alive = false;
    };
    // The joined key is the dependency: re-mint only when the set
    // of URLs actually changes, not on every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  return map;
}
