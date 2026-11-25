// Milestone 12 — Report a problem with an order (route
// /dispute/:orderId, added by the coordinator). Only the buyer of
// the order may file.
//
// The report needs a category, at least 20 characters of
// explanation, a contact email, and at least one piece of in-app
// evidence for the order — dispute evidence is a video recorded in
// the app, 10–20 seconds (see src/lib/evidence.js EVIDENCE_RULES).
// Nothing is picked from the gallery. A report with no evidence is
// refused, never filed.
//
// On success the page shows ONLY: "Report sent — under review", the
// ticket ID (PM-TKT-####), and a plain line that the PulseMarket
// team will review it.
import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { fetchOrder } from "../lib/orders";
import {
  EVIDENCE_RULES,
  fetchEvidenceForOrder,
  recordVideo,
  uploadEvidence,
} from "../lib/evidence";
import { DISPUTE_CATEGORIES, fileDispute, fetchMyDisputes } from "../lib/disputes";
import { EmptyState, GhostButton, PrimaryButton, inputCls } from "../components/ui";

const DISPUTE_RULE = EVIDENCE_RULES.dispute;

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

export default function Dispute() {
  const { orderId } = useParams();
  const { user, loading: authLoading } = useAuth();
  const [order, setOrder] = useState(null);
  const [evidence, setEvidence] = useState([]);
  const [existingTicket, setExistingTicket] = useState(null);
  const [category, setCategory] = useState(DISPUTE_CATEGORIES[0]);
  const [explanation, setExplanation] = useState("");
  const [email, setEmail] = useState("");
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState("");
  const [sentTicket, setSentTicket] = useState(null);

  // In-app dispute video capture (10–20s, MediaRecorder — same flow
  // as the Evidence Locker, fixed to kind 'dispute').
  const [recording, setRecording] = useState(false);
  const [seconds, setSeconds] = useState(0);
  const [clip, setClip] = useState(null);
  const [clipUrl, setClipUrl] = useState("");
  const [clipBusy, setClipBusy] = useState(false);
  const [clipError, setClipError] = useState("");
  const [clipNotice, setClipNotice] = useState("");
  const previewRef = useRef(null);
  const recorderRef = useRef(null);

  useEffect(() => {
    return () => {
      recorderRef.current?.stop?.();
      if (clipUrl) URL.revokeObjectURL(clipUrl);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const load = useCallback(async () => {
    if (!user || !orderId) {
      setLoading(false);
      return;
    }
    setLoading(true);
    setError("");
    try {
      const [foundOrder, rows, mine] = await Promise.all([
        fetchOrder(orderId),
        fetchEvidenceForOrder(orderId),
        fetchMyDisputes(user.id),
      ]);
      setOrder(foundOrder);
      setEvidence(rows || []);
      const open = (mine || []).find(
        (d) => d.order_id === orderId && (d.status === "open" || d.status === "under_review")
      );
      if (open) setExistingTicket(open.ticket_id);
    } catch (err) {
      setError(err?.message || "Could not load this order.");
    } finally {
      setLoading(false);
    }
  }, [user, orderId]);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    if (user?.email) setEmail(user.email);
  }, [user]);

  function resetClip() {
    if (clipUrl) URL.revokeObjectURL(clipUrl);
    setClip(null);
    setClipUrl("");
  }

  async function startRecording() {
    setClipError("");
    setClipNotice("");
    resetClip();
    setSeconds(0);
    setRecording(true);
    const rec = recordVideo({
      maxSeconds: DISPUTE_RULE.maxSeconds,
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
      setClipError(err?.message || "Could not start the camera.");
    } finally {
      recorderRef.current = null;
    }
  }

  async function uploadClip() {
    if (!clip) return;
    // A clip outside 10–20s can never count as evidence — refuse the
    // save plainly instead of storing an unverified video.
    if (clip.durationSeconds < DISPUTE_RULE.minSeconds || clip.durationSeconds > DISPUTE_RULE.maxSeconds) {
      setClipError(`That video is ${clip.durationSeconds}s — dispute evidence must be ${DISPUTE_RULE.minSeconds}–${DISPUTE_RULE.maxSeconds} seconds. Record again.`);
      return;
    }
    setClipError("");
    setClipNotice("");
    setClipBusy(true);
    try {
      const row = await uploadEvidence(orderId, {
        kind: "dispute",
        mediaType: "video",
        fileOrBlob: clip.blob,
        durationSeconds: clip.durationSeconds,
      });
      resetClip();
      setClipNotice(
        row.verified
          ? "Saved — verified ✓"
          : `Saved, but not verified — ${row.verified_reason || "it did not pass the rule."}`
      );
      await load();
    } catch (err) {
      setClipError(err?.message || "Could not save this video.");
    } finally {
      setClipBusy(false);
    }
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError("");
    setSubmitting(true);
    try {
      const { ticketId } = await fileDispute(orderId, {
        category,
        explanation,
        email,
      });
      setSentTicket(ticketId);
    } catch (err) {
      setError(err?.message || "Could not send this report. Try again.");
    } finally {
      setSubmitting(false);
    }
  }

  // Success view — only these three lines, nothing else.
  if (sentTicket || existingTicket) {
    const ticket = sentTicket || existingTicket;
    return (
      <main className="mx-auto max-w-2xl px-4 py-6">
        <h1 className="text-xl font-bold">Report sent — under review</h1>
        <p className="mt-4 text-sm">
          Your ticket ID is <span className="font-bold">{ticket}</span>
        </p>
        <p className="mt-2 text-sm text-neutral-500">
          The PulseMarket team will review it.
        </p>
      </main>
    );
  }

  if (authLoading || loading) {
    return (
      <main className="mx-auto max-w-2xl px-4 py-6">
        <p className="text-sm text-neutral-500">Loading…</p>
      </main>
    );
  }

  if (!user) {
    return (
      <main className="mx-auto max-w-2xl px-4 py-6">
        <h1 className="text-xl font-bold">Report a problem</h1>
        <div className="mt-4">
          <EmptyState
            title="Sign in to report a problem"
            body="Only the buyer of an order can report a problem with it."
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

  if (!order) {
    return (
      <main className="mx-auto max-w-2xl px-4 py-6">
        <h1 className="text-xl font-bold">Report a problem</h1>
        <p className="mt-4 text-sm text-red-600">{error || "Order not found."}</p>
      </main>
    );
  }

  if (order.buyer_id !== user.id) {
    return (
      <main className="mx-auto max-w-2xl px-4 py-6">
        <h1 className="text-xl font-bold">Report a problem</h1>
        <p className="mt-4 text-sm text-neutral-500">
          Only the buyer of this order can report a problem with it.
        </p>
      </main>
    );
  }

  // A report freezes money, so there has to be money in play: a
  // 'reserved' order has not started (cancel it instead) and a
  // closed order's money has already moved. Say so here instead of
  // showing a form that can only fail on submit.
  const DISPUTABLE_STATUSES = ["paid", "held", "shipped", "delivered"];
  if (!DISPUTABLE_STATUSES.includes(order.status)) {
    return (
      <main className="mx-auto max-w-2xl px-4 py-6">
        <h1 className="text-xl font-bold">Report a problem</h1>
        <p className="mt-4 text-sm text-neutral-500">
          {order.status === "reserved"
            ? "This order has not started yet — cancel it from the order page if you no longer want it."
            : "This order is already closed — email pulsemarketsupport@gmail.com with the order code and the team will look into it."}
        </p>
        <div className="mt-4">
          <Link to={`/order/${order.id}`}>
            <GhostButton>Back to order</GhostButton>
          </Link>
        </div>
      </main>
    );
  }

  // What the form needs before it can send — shown plainly next to
  // the button, so the student is not left tapping "Send report"
  // only to be refused. The server-side checks in fileDispute stay
  // as the backstop: a packing or unboxing video does NOT count
  // here, only a verified dispute video does.
  const hasVerifiedDisputeVideo = evidence.some(
    (r) => r.kind === "dispute" && r.verified === true
  );
  const explanationOk = explanation.trim().length >= 20;
  const emailValid = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim());
  const canSend = explanationOk && emailValid && hasVerifiedDisputeVideo;
  const sendBlockers = [
    !explanationOk ? "explain what happened (at least 20 characters)" : null,
    !emailValid ? "enter a valid email for the reply" : null,
    !hasVerifiedDisputeVideo ? "record a verified dispute video below (10–20 seconds)" : null,
  ].filter(Boolean);

  return (
    <main className="mx-auto max-w-2xl px-4 py-6">
      <h1 className="text-xl font-bold">Report a problem</h1>
      <p className="mt-1 text-sm text-neutral-500">
        Order {order.code} · {order.status}
        {order.frozen ? " · Money is frozen while a report is open" : ""}
      </p>

      <form onSubmit={handleSubmit} className="mt-6 space-y-5">
        <div>
          <label className="text-xs font-semibold text-neutral-500" htmlFor="dispute-category">
            What went wrong?
          </label>
          <select
            id="dispute-category"
            className={`${inputCls} mt-1`}
            value={category}
            onChange={(e) => setCategory(e.target.value)}
            disabled={submitting}
          >
            {DISPUTE_CATEGORIES.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="text-xs font-semibold text-neutral-500" htmlFor="dispute-explanation">
            Explain what happened
          </label>
          <textarea
            id="dispute-explanation"
            className={`${inputCls} mt-1 min-h-28`}
            value={explanation}
            onChange={(e) => setExplanation(e.target.value.slice(0, 2000))}
            placeholder="Say what you received, what was wrong, and what you expected — at least 20 characters."
            maxLength={2000}
            disabled={submitting}
          />
          <p className="mt-1 text-xs text-neutral-500">
            {explanation.trim().length} / 20 characters minimum
            {explanation.trim().length > 0 ? ` · ${explanation.trim().length}/2000 max` : ""}
          </p>
        </div>

        <div>
          <label className="text-xs font-semibold text-neutral-500" htmlFor="dispute-email">
            Email for the reply
          </label>
          <input
            id="dispute-email"
            type="email"
            className={`${inputCls} mt-1`}
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            disabled={submitting}
          />
        </div>

        <div>
          <p className="text-xs font-semibold text-neutral-500">Evidence</p>
          <p className="mt-1 text-xs text-neutral-500">
            A report needs at least one piece of evidence recorded in the app.{" "}
            {DISPUTE_RULE.ruleText}
          </p>
          {hasVerifiedDisputeVideo ? (
            <p className="mt-2 text-sm font-semibold text-brown-dark">
              ✓ Verified dispute video ready — your report can be sent.
            </p>
          ) : (
            <p className="mt-2 text-sm text-neutral-500">
              No verified dispute video yet — record one below (10–20 seconds). Other videos or photos on this order do not count for a report.
            </p>
          )}

          {evidence.length === 0 ? (
            <p className="mt-2 text-sm text-neutral-500">
              No evidence for this order yet — record a video below first.
            </p>
          ) : (
            <ul className="mt-2 space-y-2">
              {evidence.map((item) => (
                <li
                  key={item.id}
                  className="flex gap-3 rounded-xl border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
                >
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
                      alt={item.kind}
                      className="h-20 w-28 shrink-0 rounded-lg bg-neutral-100 object-cover dark:bg-neutral-900"
                    />
                  )}
                  <div className="min-w-0 flex-1">
                    <p className="text-sm font-semibold">{item.kind}</p>
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
                  </div>
                </li>
              ))}
            </ul>
          )}

          <div className="mt-3 rounded-xl border border-dashed border-neutral-300 bg-neutral-50 p-3 dark:border-neutral-700 dark:bg-neutral-950">
            <p className="text-xs font-semibold text-neutral-500">
              Record dispute evidence — video, 10–20 seconds, in the app
            </p>
            {recording ? (
              <div className="mt-3">
                <video
                  ref={previewRef}
                  autoPlay
                  muted
                  playsInline
                  className="aspect-video w-full rounded-lg bg-black object-cover"
                />
                <p className="mt-2 text-center text-lg font-bold tabular-nums">
                  {seconds}s / {DISPUTE_RULE.maxSeconds}s
                </p>
                <p className="text-center text-xs text-neutral-500">
                  Recording stops automatically at {DISPUTE_RULE.maxSeconds}s. Show the problem clearly.
                </p>
                <div className="mt-2 text-center">
                  <GhostButton type="button" onClick={() => recorderRef.current?.stop?.()}>
                    Stop recording
                  </GhostButton>
                </div>
              </div>
            ) : clip ? (
              <div className="mt-3">
                <video src={clipUrl} controls className="aspect-video w-full rounded-lg bg-black object-cover" />
                <p className="mt-2 text-center text-sm">
                  Recorded {clip.durationSeconds}s —{" "}
                  {clip.durationSeconds < DISPUTE_RULE.minSeconds || clip.durationSeconds > DISPUTE_RULE.maxSeconds
                    ? "outside 10–20s, record again."
                    : "ready to save."}
                </p>
                <div className="mt-2 flex justify-center gap-2">
                  <PrimaryButton
                    type="button"
                    onClick={uploadClip}
                    disabled={
                      clipBusy ||
                      clip.durationSeconds < DISPUTE_RULE.minSeconds ||
                      clip.durationSeconds > DISPUTE_RULE.maxSeconds
                    }
                  >
                    {clipBusy ? "Saving…" : "Save this video"}
                  </PrimaryButton>
                  <GhostButton type="button" onClick={resetClip} disabled={clipBusy}>
                    Record again
                  </GhostButton>
                </div>
              </div>
            ) : (
              <div className="mt-3">
                <PrimaryButton type="button" onClick={startRecording} disabled={clipBusy}>
                  Record video in the app
                </PrimaryButton>
              </div>
            )}
            {clipError ? <p className="mt-2 text-sm text-red-600">{clipError}</p> : null}
            {clipNotice ? <p className="mt-2 text-sm font-semibold text-brown-dark">{clipNotice}</p> : null}
          </div>
        </div>

        {error ? <p className="text-sm text-red-600">{error}</p> : null}

        <PrimaryButton type="submit" disabled={submitting || !canSend}>
          {submitting ? "Sending…" : "Send report"}
        </PrimaryButton>
        {!canSend && !submitting ? (
          <p className="text-sm text-neutral-500">
            To send this report, {sendBlockers.join("; ")}.
          </p>
        ) : null}
      </form>

      <p className="mt-8 text-center text-xs text-neutral-500">
        Questions? Email pulsemarketsupport@gmail.com
      </p>
    </main>
  );
}
