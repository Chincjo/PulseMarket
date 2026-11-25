// Milestone 9 — Evidence Locker (route /evidence, added by the
// coordinator). The student's locker: all their evidence grouped by
// order, with the in-app camera capture for each kind.
//
// Rules (see src/lib/evidence.js):
//   - Dispute evidence: video, 10–20 seconds.
//   - Packing video: 15–30 seconds.
//   - Unboxing video: no longer than 60 seconds.
//   - Handoff / waybill / receipt / return: photos, no duration rule.
// Videos are recorded IN THE APP with MediaRecorder — nothing is
// picked from the gallery. A brown ✓ "Verified" tick shows ONLY when
// verified=true; anything unverified shows the plain reason instead.
// There is no green anywhere in this theme — the verified tick is
// brown, like every other check in the app.
import { useCallback, useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { fetchMyOrders } from "../lib/orders";
import { fetchListing } from "../lib/listings";
import {
  EVIDENCE_RULES,
  deleteEvidence,
  fetchMyEvidence,
  recordVideo,
  uploadEvidence,
} from "../lib/evidence";
import { EmptyState, GhostButton, PrimaryButton, inputCls } from "../components/ui";

const KIND_OPTIONS = [
  { value: "packing", label: "Packing video — 15–30s" },
  { value: "unboxing", label: "Unboxing video — max 60s" },
  { value: "dispute", label: "Dispute evidence — 10–20s" },
  { value: "handoff", label: "Photo — Handoff" },
  { value: "waybill", label: "Photo — Waybill" },
  { value: "receipt", label: "Photo — Receipt" },
  { value: "return", label: "Photo — Return" },
];

function kindLabel(kind) {
  return EVIDENCE_RULES[kind]?.label || kind;
}

function timeAgo(iso) {
  if (!iso) return "";
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000));
  if (seconds < 60) return "just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days}d ago`;
  return new Date(iso).toLocaleDateString("en-NG");
}

// One evidence item: thumbnail, kind, duration, brown ✓ when verified,
// plain reason when not.
function EvidenceItem({ item, onDeleted }) {
  const [deleting, setDeleting] = useState(false);
  const [error, setError] = useState("");

  async function handleDelete() {
    if (!window.confirm("Delete this evidence? This cannot be undone.")) return;
    setError("");
    setDeleting(true);
    try {
      await deleteEvidence(item.id);
      onDeleted(item.id);
    } catch (err) {
      setError(err?.message || "Could not delete this evidence.");
    } finally {
      setDeleting(false);
    }
  }

  return (
    <li className="flex gap-3 rounded-xl border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950">
      {item.media_type === "video" ? (
        <video
          src={item.url}
          controls
          preload="metadata"
          className="h-20 w-28 shrink-0 rounded-lg bg-black object-cover"
        />
      ) : (
        <img
          src={item.url}
          alt={kindLabel(item.kind)}
          className="h-20 w-28 shrink-0 rounded-lg bg-neutral-100 object-cover dark:bg-neutral-900"
        />
      )}
      <div className="min-w-0 flex-1">
        <p className="text-sm font-semibold">{kindLabel(item.kind)}</p>
        <p className="text-xs text-neutral-500">
          {item.media_type === "video"
            ? `Video · ${item.duration_seconds ?? "?"}s`
            : "Photo"}
          {" · "}
          {timeAgo(item.created_at)}
        </p>
        {item.verified ? (
          <p className="mt-1 inline-flex items-center gap-1 rounded-full bg-brown-soft px-2 py-0.5 text-xs font-semibold text-brown-dark">
            <span aria-hidden="true">✓</span> Verified
          </p>
        ) : (
          <p className="mt-1 text-xs text-neutral-500">
            Not verified — {item.verified_reason || "it did not pass the rule for this kind."}
          </p>
        )}
        {error ? <p className="mt-1 text-xs text-red-600">{error}</p> : null}
      </div>
      <button
        type="button"
        onClick={handleDelete}
        disabled={deleting}
        className="self-start text-xs font-semibold text-neutral-500 underline disabled:opacity-50"
      >
        {deleting ? "Deleting…" : "Delete"}
      </button>
    </li>
  );
}

// Upload box for one order: kind picker, rule text, in-app camera
// capture (MediaRecorder for video, camera input for photos), live
// duration while recording.
function UploadBox({ order, onUploaded }) {
  const [kind, setKind] = useState("unboxing");
  const [recording, setRecording] = useState(false);
  const [seconds, setSeconds] = useState(0);
  const [clip, setClip] = useState(null);
  const [clipUrl, setClipUrl] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const previewRef = useRef(null);
  const recorderRef = useRef(null);
  const photoInputRef = useRef(null);

  const rule = EVIDENCE_RULES[kind];
  const isVideo = rule?.mediaType === "video";

  // Stop any live camera stream if this box unmounts mid-recording.
  useEffect(() => {
    return () => {
      recorderRef.current?.stop?.();
      if (clipUrl) URL.revokeObjectURL(clipUrl);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function resetClip() {
    if (clipUrl) URL.revokeObjectURL(clipUrl);
    setClip(null);
    setClipUrl("");
  }

  async function startRecording() {
    setError("");
    setNotice("");
    resetClip();
    setSeconds(0);
    setRecording(true);
    const rec = recordVideo({
      maxSeconds: rule.maxSeconds,
      onData: (stream) => {
        if (previewRef.current) previewRef.current.srcObject = stream;
      },
      onTick: (s) => setSeconds(s),
    });
    recorderRef.current = rec;
    try {
      const result = await rec;
      setRecording(false);
      setClip(result);
      setClipUrl(URL.createObjectURL(result.blob));
      setSeconds(result.durationSeconds);
    } catch (err) {
      setRecording(false);
      setError(err?.message || "Could not start the camera.");
    } finally {
      recorderRef.current = null;
    }
  }

  function stopRecording() {
    recorderRef.current?.stop?.();
  }

  async function uploadClip() {
    if (!clip) return;
    setError("");
    setNotice("");
    setBusy(true);
    try {
      const row = await uploadEvidence(order.id, {
        kind,
        mediaType: "video",
        fileOrBlob: clip.blob,
        durationSeconds: clip.durationSeconds,
      });
      resetClip();
      setNotice(
        row.verified
          ? "Saved — verified ✓"
          : `Saved, but not verified — ${row.verified_reason || "it did not pass the rule."}`
      );
      onUploaded();
    } catch (err) {
      setError(err?.message || "Could not save this video.");
    } finally {
      setBusy(false);
    }
  }

  async function uploadPhoto(file) {
    if (!file) return;
    setError("");
    setNotice("");
    setBusy(true);
    try {
      const row = await uploadEvidence(order.id, {
        kind,
        mediaType: "photo",
        fileOrBlob: file,
      });
      setNotice(row.verified ? "Saved — verified ✓" : "Saved.");
      onUploaded();
    } catch (err) {
      setError(err?.message || "Could not save this photo.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="rounded-xl border border-dashed border-neutral-300 bg-neutral-50 p-3 dark:border-neutral-700 dark:bg-neutral-950">
      <label className="text-xs font-semibold text-neutral-500" htmlFor={`kind-${order.id}`}>
        Add evidence
      </label>
      <select
        id={`kind-${order.id}`}
        className={`${inputCls} mt-1`}
        value={kind}
        onChange={(e) => {
          setKind(e.target.value);
          setError("");
          setNotice("");
          resetClip();
        }}
        disabled={recording || busy}
      >
        {KIND_OPTIONS.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
      <p className="mt-1 text-xs text-neutral-500">{rule?.ruleText}</p>

      {isVideo ? (
        <div className="mt-3">
          {recording ? (
            <div>
              <video
                ref={previewRef}
                autoPlay
                muted
                playsInline
                className="aspect-video w-full rounded-lg bg-black object-cover"
              />
              <p className="mt-2 text-center text-lg font-bold tabular-nums">
                {seconds}s / {rule.maxSeconds}s
              </p>
              <p className="text-center text-xs text-neutral-500">
                Recording stops automatically at {rule.maxSeconds}s.
              </p>
              <div className="mt-2 text-center">
                <GhostButton type="button" onClick={stopRecording}>
                  Stop recording
                </GhostButton>
              </div>
            </div>
          ) : clip ? (
            <div>
              <video src={clipUrl} controls className="aspect-video w-full rounded-lg bg-black object-cover" />
              <p className="mt-2 text-center text-sm">
                Recorded {clip.durationSeconds}s — {clip.durationSeconds > rule.maxSeconds ? "too long, record again." : "ready to save."}
              </p>
              <div className="mt-2 flex justify-center gap-2">
                <PrimaryButton type="button" onClick={uploadClip} disabled={busy}>
                  {busy ? "Saving…" : "Save this video"}
                </PrimaryButton>
                <GhostButton type="button" onClick={resetClip} disabled={busy}>
                  Record again
                </GhostButton>
              </div>
            </div>
          ) : (
            <PrimaryButton type="button" onClick={startRecording} disabled={busy}>
              Record video in the app
            </PrimaryButton>
          )}
        </div>
      ) : (
        <div className="mt-3">
          <input
            ref={photoInputRef}
            type="file"
            accept="image/*"
            capture="environment"
            className="hidden"
            onChange={(e) => {
              const file = e.target.files?.[0];
              e.target.value = "";
              if (file) uploadPhoto(file);
            }}
          />
          <PrimaryButton
            type="button"
            onClick={() => photoInputRef.current?.click()}
            disabled={busy}
          >
            {busy ? "Saving…" : "Take a photo in the app"}
          </PrimaryButton>
        </div>
      )}

      {error ? <p className="mt-2 text-sm text-red-600">{error}</p> : null}
      {notice ? <p className="mt-2 text-sm font-semibold text-brown-dark">{notice}</p> : null}
    </div>
  );
}

export default function EvidenceLocker() {
  const { user } = useAuth();
  const [orders, setOrders] = useState([]);
  const [evidence, setEvidence] = useState([]);
  const [titles, setTitles] = useState({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");

  const load = useCallback(async () => {
    if (!user) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError("");
    try {
      const [myOrders, myEvidence] = await Promise.all([
        fetchMyOrders(user.id),
        fetchMyEvidence(user.id),
      ]);
      setOrders(myOrders || []);
      setEvidence(myEvidence || []);
      // Item titles come from the listings, one fetch per order.
      const listingIds = [...new Set((myOrders || []).map((o) => o.listing_id).filter(Boolean))];
      const entries = await Promise.all(
        listingIds.map(async (id) => {
          try {
            const listing = await fetchListing(id);
            return [id, listing?.title || "Item"];
          } catch {
            return [id, "Item"];
          }
        })
      );
      setTitles(Object.fromEntries(entries));
    } catch (err) {
      setError(err?.message || "Could not load your evidence.");
    } finally {
      setLoading(false);
    }
  }, [user]);

  useEffect(() => {
    load();
  }, [load]);

  function handleDeleted(id) {
    setEvidence((prev) => prev.filter((row) => row.id !== id));
  }

  if (!user) {
    return (
      <main className="mx-auto max-w-2xl px-4 py-6">
        <h1 className="text-xl font-bold">Evidence Locker</h1>
        <div className="mt-4">
          <EmptyState
            title="Sign in to see your evidence"
            body="Your packing videos, unboxing videos and photos live here, grouped by order."
            action={
              <Link to="/signin">
                <PrimaryButton type="button">Sign in</PrimaryButton>
              </Link>
            }
          />
        </div>
      </main>
    );
  }

  const byOrder = {};
  for (const row of evidence) {
    if (!byOrder[row.order_id]) byOrder[row.order_id] = [];
    byOrder[row.order_id].push(row);
  }

  return (
    <main className="mx-auto max-w-2xl px-4 py-6">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-xl font-bold">Evidence Locker</h1>
          <p className="mt-1 text-sm text-neutral-500">
            Photos and videos recorded in the app, grouped by order. A brown ✓ means the
            recording passed its rule and counts — for example, a shipping order cannot be
            confirmed delivered until your unboxing video is verified.
          </p>
        </div>
        <Link to="/dashboard">
          <GhostButton type="button">My orders</GhostButton>
        </Link>
      </div>

      {loading ? (
        <p className="mt-6 text-sm text-neutral-500">Loading your evidence…</p>
      ) : error ? (
        <p className="mt-6 text-sm text-red-600">{error}</p>
      ) : (
        <div className="mt-6 space-y-6">
          {evidence.length === 0 ? (
            <EmptyState
              title="No evidence yet"
              body="Nothing recorded yet. Open an order below and record your first video or photo in the app — packing videos are 15–30 seconds, unboxing videos no longer than 60 seconds, and dispute evidence 10–20 seconds."
            />
          ) : null}

          {orders.length === 0 ? (
            <EmptyState
              title="No orders yet"
              body="Evidence is recorded per order. Once you buy or sell something, it will show up here."
              action={
                <Link to="/">
                  <PrimaryButton type="button">Browse items</PrimaryButton>
                </Link>
              }
            />
          ) : (
            orders.map((order) => {
              const items = byOrder[order.id] || [];
              const isBuyer = order.buyer_id === user.id;
              return (
                <section
                  key={order.id}
                  className="rounded-2xl border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <h2 className="font-semibold">{titles[order.listing_id] || "Item"}</h2>
                      <p className="text-xs text-neutral-500">
                        {order.code} · {isBuyer ? "You bought this" : "You sold this"} ·{" "}
                        {order.delivery_method === "shipping" ? "Shipping" : "Meet in person"} ·{" "}
                        {order.status}
                      </p>
                    </div>
                    <Link
                      to={`/order/${order.id}`}
                      className="shrink-0 text-xs font-semibold text-brown-dark underline"
                    >
                      View order
                    </Link>
                  </div>

                  {items.length === 0 ? (
                    <p className="mt-3 text-sm text-neutral-500">
                      No evidence for this order yet.
                    </p>
                  ) : (
                    <ul className="mt-3 space-y-2">
                      {items.map((item) => (
                        <EvidenceItem key={item.id} item={item} onDeleted={handleDeleted} />
                      ))}
                    </ul>
                  )}

                  <div className="mt-3">
                    <UploadBox order={order} onUploaded={load} />
                  </div>
                </section>
              );
            })
          )}
        </div>
      )}

      <p className="mt-8 text-center text-xs text-neutral-500">
        Questions about evidence? Email pulsemarketsupport@gmail.com
      </p>
    </main>
  );
}
