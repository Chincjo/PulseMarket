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
import { supabase } from "./supabase";

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
    .select("id, buyer_id, seller_id")
    .eq("id", orderId)
    .maybeSingle();
  if (orderError) throw orderError;
  if (!order) throw new Error("Order not found.");
  if (order.buyer_id !== user.id && order.seller_id !== user.id) {
    throw new Error("Only the buyer or seller of this order can add evidence for it.");
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
  // The file must be what the kind claims it is — a photo renamed
  // .webm (or a video file passed as a photo) never counts, whatever
  // its name or extension says. Browsers that report no MIME type
  // (empty blob.type) skip this check.
  if (blob && blob.type) {
    if (mediaType === "photo" && !blob.type.startsWith("image/")) {
      throw new Error("That file is not a photo — take a photo in the app.");
    }
    if (mediaType === "video" && !blob.type.startsWith("video/")) {
      throw new Error("That file is not a video — record a video in the app.");
    }
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
    .order("created_at", { ascending: false });
  if (error) {
    dbError(error, "fetch evidence for order");
    return [];
  }
  return data || [];
}

// All evidence across the user's orders, newest first.
export async function fetchMyEvidence(userId) {
  if (!supabase || !userId) return [];
  const { data, error } = await supabase
    .from("evidence")
    .select("*")
    .eq("user_id", userId)
    .order("created_at", { ascending: false });
  if (error) {
    dbError(error, "fetch my evidence");
    return [];
  }
  return data || [];
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
  const path = storagePathFromUrl(row.url);
  if (path) {
    const { error: storageError } = await supabase.storage
      .from(EVIDENCE_BUCKET)
      .remove([path]);
    if (storageError) {
      // Log it and carry on — the row must still go, or the student
      // is left with evidence they cannot remove.
      dbError(storageError, "delete evidence file");
    }
  }
  const { error } = await supabase.from("evidence").delete().eq("id", id);
  if (error) throw error;
  return true;
}

// Public bucket URLs look like
// .../storage/v1/object/public/evidence-media/<user-id>/evidence-....jpg
// — the part after the bucket name is the storage path.
export function storagePathFromUrl(url) {
  if (!url) return null;
  const marker = `/object/public/${EVIDENCE_BUCKET}/`;
  const idx = String(url).indexOf(marker);
  if (idx === -1) return null;
  return String(url).slice(idx + marker.length) || null;
}
