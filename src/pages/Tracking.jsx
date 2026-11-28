// Milestone 8 — Tracking (route /tracking/:orderId, added by the
// coordinator). Seller view: shipping proof (Waybill Snap) + checkpoints.
// Buyer view: checkpoint timeline, courier + waybill, delivery PIN,
// PIN confirmation, returns. Same-city (Chowdeck Relay) adds a rider
// card + progress bar. Interstate shows checkpoint stops only.
//
// HONESTY RULE: there is no rider GPS feed in this system. This page
// never draws a live map with a moving rider marker and never claims
// live GPS — it shows the progress bar, the rider card and the PIN,
// with the plain note "Live rider map arrives when a rider app is
// connected."
import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { formatNaira } from "../lib/fees";
import { fetchListing } from "../lib/listings";
import { fetchConversationForListing } from "../lib/chat";
import { OWNER_EMAIL } from "../lib/payments";
import { useAuth } from "../lib/auth";
import { EmptyState, GhostButton, PrimaryButton, inputCls } from "../components/ui";
import { fetchEvidenceForOrderChecked, useSignedEvidenceUrls } from "../lib/evidence";
import {
  CHECKPOINT_LABELS,
  CHECKPOINT_STATUSES,
  RETURN_REASONS,
  addCheckpoint,
  confirmDeliveryWithPin,
  courierEarnsAdvance,
  courierTiers,
  fetchTracking,
  openReturn,
  rejectReturn,
  resolveReturn,
  retryShippingAdvance,
  submitShippingProof,
  updateRiderDetails,
} from "../lib/shipping";

// The 15–30s packing video is Milestone 9's Evidence Locker work. It
// is shown here so the seller knows it is coming — it does NOT count
// toward proof completeness yet.
const PACKING_VIDEO_NOTE = "Packing video — arrives with the Evidence Locker";

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

function copyText(text, done) {
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).then(() => done(true)).catch(() => done(false));
  } else {
    done(false);
  }
}

// Read a camera / file input into a data URL for preview + upload.
function fileToDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error("Could not read that photo. Try again."));
    reader.readAsDataURL(file);
  });
}

function Check({ done, label, hint }) {
  return (
    <li className="flex items-start gap-2 text-sm">
      <span
        className={`mt-0.5 flex h-5 w-5 shrink-0 items-center justify-center rounded-full text-xs font-bold ${
          done ? "bg-brown text-white" : "border border-neutral-300 text-neutral-400 dark:border-neutral-700"
        }`}
      >
        {done ? "✓" : "·"}
      </span>
      <span>
        <span className={done ? "font-semibold" : "text-neutral-500"}>{label}</span>
        {hint ? <span className="block text-xs text-neutral-500">{hint}</span> : null}
      </span>
    </li>
  );
}

export default function Tracking() {
  const { orderId } = useParams();
  const { user } = useAuth();
  const [order, setOrder] = useState(null);
  const [listing, setListing] = useState(null);
  const [checkpoints, setCheckpoints] = useState([]);
  // Milestone 20 (M-6): checkpoint, waybill and receipt photos
  // render through short-lived signed URLs (the evidence-media
  // bucket goes private) — stored URLs are the fallback until then.
  const signedPhotoUrls = useSignedEvidenceUrls([
    ...(checkpoints || []).map((c) => c.photo),
    order?.waybill_photo,
    order?.receipt_photo,
  ]);
  const [chatId, setChatId] = useState(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState("");
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [copied, setCopied] = useState("");

  // Shipping proof form (seller)
  const [waybillNumber, setWaybillNumber] = useState("");
  const [waybillPhoto, setWaybillPhoto] = useState(null);
  const [receiptPhoto, setReceiptPhoto] = useState(null);
  const [driverPhone, setDriverPhone] = useState("");

  // Checkpoint form (seller)
  const [cpStatus, setCpStatus] = useState("picked_up");
  const [cpLocation, setCpLocation] = useState("");
  const [cpNote, setCpNote] = useState("");
  const [cpPhoto, setCpPhoto] = useState(null);

  // Rider details form (seller, Chowdeck Relay only — Milestone 19)
  const [riderName, setRiderName] = useState("");
  const [riderPhone, setRiderPhone] = useState("");

  // PIN + return forms (buyer)
  const [pinInput, setPinInput] = useState("");
  const [returnReason, setReturnReason] = useState(RETURN_REASONS[0]);
  const [returnFault, setReturnFault] = useState("seller");
  // Team attestation for a return resolved without a verified
  // return photo (the team saw the item come back themselves).
  const [returnAttested, setReturnAttested] = useState(false);
  // Whether the buyer has a verified unboxing video — the PIN
  // confirm is gated on it in lib, so the button is disabled here
  // with a hint instead of failing on tap. `evidenceFailed` means
  // the check itself failed, which is not "no video".
  const [hasVerifiedUnboxing, setHasVerifiedUnboxing] = useState(false);
  const [evidenceFailed, setEvidenceFailed] = useState(false);
  // Entry guard for run(): `busy` only disables the buttons AFTER a
  // re-render, so two taps in the same tick both fired.
  const busyRef = useRef("");

  const isBuyer = user && order && order.buyer_id === user.id;
  const isSeller = user && order && order.seller_id === user.id;
  const isOwner = user?.email === OWNER_EMAIL;
  const isSameCity = order?.courier === "Chowdeck Relay";
  const isInterstate = order && !isSameCity;
  // The PIN confirm is gated on the buyer's verified unboxing video
  // (lib rule in orders.js) — disable the button with a hint when
  // it is missing, instead of letting the tap fail.
  const unboxingMissing =
    order?.delivery_method === "shipping" &&
    order.status === "shipped" &&
    !hasVerifiedUnboxing &&
    !evidenceFailed;

  const load = useCallback(async () => {
    try {
      const result = await fetchTracking(orderId);
      if (result) {
        setOrder(result.order);
        setCheckpoints(result.checkpoints || []);
        const item = await fetchListing(result.order.listing_id);
        setListing(item);
        // The lib's PIN confirm refuses a shipping order without
        // the BUYER's verified unboxing video — check it here so
        // the button is disabled with a hint instead of failing on
        // tap (same pattern as OrderDetail).
        const { rows, failed } = await fetchEvidenceForOrderChecked(result.order.id);
        setEvidenceFailed(failed);
        setHasVerifiedUnboxing(
          (rows || []).some(
            (r) =>
              r.kind === "unboxing" &&
              r.media_type === "video" &&
              r.verified === true &&
              r.user_id === result.order.buyer_id
          )
        );
        if (user) {
          // One query for this order's chat — the old code loaded the
          // whole conversation list (with a last-message + unread
          // query per chat) just to find one chat id.
          const match = await fetchConversationForListing(result.order.listing_id, user.id);
          if (match) setChatId(match.id);
        }
      }
    } catch (err) {
      setError(err?.message || "Could not load tracking. Try again.");
    } finally {
      setLoading(false);
    }
  }, [orderId, user]);

  useEffect(() => {
    load();
  }, [load]);

  // Pre-fill the rider form with whatever is already saved, so the
  // seller corrects the details instead of retyping them. Only runs
  // when a different order loads, never while the seller is typing.
  useEffect(() => {
    if (order) {
      setRiderName(order.rider_name || "");
      setRiderPhone(order.rider_phone || "");
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [order?.id]);

  async function run(action, fn, onDone) {
    // Entry guard: `busy` only disables the buttons AFTER a
    // re-render, so two taps in the same tick (or two different
    // buttons) both used to fire the same money action twice.
    if (busyRef.current) return;
    busyRef.current = action;
    setError("");
    setNotice("");
    setBusy(action);
    try {
      const result = await fn();
      if (result?.order) setOrder(result.order);
      if (result?.reason) setNotice(result.reason);
      else if (result?.note) setNotice(result.note);
      else setNotice("Done.");
      if (onDone) onDone(result);
      await load();
    } catch (err) {
      setError(err?.message || "Something went wrong. Please try again.");
    } finally {
      busyRef.current = "";
      setBusy("");
    }
  }

  async function onPhotoInput(e, setPhoto) {
    const file = e.target.files?.[0];
    if (!file) return;
    if (file.size > 10 * 1024 * 1024) {
      setError("That photo is too big — keep photos under 10MB.");
      e.target.value = "";
      return;
    }
    try {
      setPhoto(await fileToDataUrl(file));
    } catch (err) {
      setError(err?.message || "Could not read that photo.");
    }
  }

  // Shipping-proof + checkpoint fields had no limits: a 10,000-char
  // waybill number or a nonsense driver phone went straight to the
  // order. Validate here before anything is submitted.
  function proofReady() {
    if (!waybillNumber.trim()) {
      setError("Enter the waybill number.");
      return false;
    }
    if (waybillNumber.trim().length > 64) {
      setError("Keep the waybill number under 64 characters.");
      return false;
    }
    if (!waybillPhoto) {
      setError("Take a photo of the waybill first.");
      return false;
    }
    const phone = driverPhone.trim();
    if (phone && !/^\+?[0-9][0-9 ()-]{6,14}$/.test(phone)) {
      setError("That driver phone number does not look right.");
      return false;
    }
    return true;
  }

  function checkpointReady() {
    if (cpLocation.trim().length > 120) {
      setError("Keep the location under 120 characters.");
      return false;
    }
    if (cpNote.trim().length > 280) {
      setError("Keep the note under 280 characters.");
      return false;
    }
    return true;
  }

  if (loading) {
    return <p className="py-10 text-center text-sm text-neutral-500">Loading tracking…</p>;
  }
  if (!order) {
    return (
      <EmptyState
        title="Order not found"
        body="It may have been removed, or the shipping tables have not been switched on yet."
        action={
          <Link to="/dashboard">
            <GhostButton>Back to dashboard</GhostButton>
          </Link>
        }
      />
    );
  }
  if (!isBuyer && !isSeller && !isOwner) {
    return (
      <EmptyState
        title="You are not part of this order"
        body="Tracking is only visible to the buyer, the seller and the PulseMarket team."
        action={
          <Link to="/dashboard">
            <GhostButton>Back to dashboard</GhostButton>
          </Link>
        }
      />
    );
  }

  const tiers = courierTiers(order.item_price);
  // The tiers are interstate-only. Chowdeck Relay is the same-city
  // courier and Bus Park Waybill is the always-allowed fallback, so
  // neither is "outside the tier" — the old check warned the seller
  // to contact the team before shipping every legitimate same-city
  // or bus-park order.
  const courierAllowed =
    order.courier === "Chowdeck Relay" ||
    order.courier === "Bus Park Waybill" ||
    tiers.allowedCouriers.includes(order.courier);
  const proofChecklist = {
    waybillNumber: waybillNumber.trim().length > 0 || Boolean(order.waybill_number),
    waybillPhoto: Boolean(waybillPhoto) || Boolean(order.waybill_photo),
    receiptPhoto: Boolean(receiptPhoto) || Boolean(order.receipt_photo),
  };
  const lastCheckpoint = checkpoints.length > 0 ? checkpoints[checkpoints.length - 1] : null;
  const delivered = ["delivered", "released"].includes(order.status);

  // Same-city progress bar, driven by checkpoints only.
  const progressSteps = ["Placed", "Confirmed", "Picked up", "On its way", "Delivered"];
  let progressIndex = 0;
  if (["paid", "held", "shipped", "delivered", "released"].includes(order.status)) progressIndex = 1;
  if (checkpoints.some((c) => c.status === "picked_up")) progressIndex = 2;
  if (checkpoints.some((c) => ["left_origin", "stopped", "arrived_terminal", "out_for_delivery", "ready_for_pickup"].includes(c.status))) progressIndex = 3;
  if (checkpoints.some((c) => c.status === "delivered") || delivered) progressIndex = 4;

  const showProofForm = isSeller && order.status === "held" && order.delivery_method === "shipping" && !order.frozen;
  const showCheckpointForm = isSeller && ["shipped", "delivered"].includes(order.status) && !order.frozen;
  // Milestone 19, Decision 6: the seller enters the rider's name
  // and phone for a same-city Chowdeck Relay order, only while the
  // money is held or the order has shipped. Any other courier or
  // status keeps rider details team-only (see the database rule).
  const showRiderForm = isSeller && isSameCity && ["held", "shipped"].includes(order.status);

  return (
    <div className="space-y-5">
      <Link to={`/order/${order.id}`} className="text-sm font-semibold text-brown">
        ← Back to order {order.code}
      </Link>
      <div>
        <h1 className="text-2xl font-bold">Tracking</h1>
        <p className="mt-1 text-sm text-neutral-500">
          {listing?.title || "Item"} · Order {order.code}
        </p>
        <p className="text-sm">
          Status: <span className="font-bold capitalize">{order.status}</span>
          {order.delivery_method === "shipping"
            ? ` · Shipping to ${order.ship_to_state || "—"} via ${order.courier || "courier to be agreed"}`
            : " · Meet in person"}
        </p>
      </div>

      {notice && <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm dark:bg-neutral-900">{notice}</p>}
      {error && <p className="rounded-xl bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}

      {/* ---- Same-city: progress bar + rider card (no live map) ---- */}
      {isSameCity && (
        <section className="space-y-4 rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <h2 className="text-lg font-bold">Same-city delivery — Chowdeck Relay</h2>
          <ol className="space-y-2">
            {progressSteps.map((step, i) => (
              <li key={step} className="flex items-center gap-2 text-sm">
                <span
                  className={`flex h-6 w-6 items-center justify-center rounded-full text-xs font-bold ${
                    i < progressIndex
                      ? "bg-brown text-white"
                      : i === progressIndex
                        ? "border-2 border-brown text-brown"
                        : "border border-neutral-300 text-neutral-400 dark:border-neutral-700"
                  }`}
                >
                  {i + 1}
                </span>
                <span className={i <= progressIndex ? "font-semibold" : "text-neutral-500"}>{step}</span>
              </li>
            ))}
          </ol>
          <div className="rounded-xl border border-brown/40 bg-brown-soft p-3">
            <p className="text-sm font-bold">Rider</p>
            {order.rider_name || order.rider_phone ? (
              <>
                <p className="mt-1 text-sm">{order.rider_name || "Rider assigned"}</p>
                {order.rider_phone && (
                  <p className="text-sm">
                    <a href={`tel:${order.rider_phone}`} className="font-semibold text-brown underline">
                      Call rider — {order.rider_phone}
                    </a>
                  </p>
                )}
                {chatId && (
                  <p className="mt-2 text-sm">
                    <Link to={`/chat/${chatId}`} className="font-semibold text-brown underline">
                      Chat about this order
                    </Link>
                  </p>
                )}
              </>
            ) : (
              <p className="mt-1 text-sm text-neutral-500">
                {isSeller
                  ? showRiderForm
                    ? "No rider details saved yet — add them below."
                    : "Rider details can be added once the money is held."
                  : "No rider assigned yet — the seller has not added the rider's name and phone number. Ask the seller in chat if you need them."}
              </p>
            )}
          </div>
          {/* Milestone 19, Decision 6 — seller enters the rider */}
          {showRiderForm && !order.frozen && (
            <div className="space-y-2 rounded-xl border border-neutral-200 p-3 dark:border-neutral-800">
              <h3 className="text-sm font-bold">Rider details</h3>
              <p className="text-xs text-neutral-500">
                Add the Chowdeck rider's name and phone number so the buyer can
                call them directly. You can correct them here any time while
                the order is held or shipped.
              </p>
              <label className="block text-sm font-semibold">
                Rider name
                <input
                  className={`${inputCls} mt-1`}
                  placeholder="e.g. Chinedu Okoro"
                  maxLength={120}
                  value={riderName}
                  onChange={(e) => setRiderName(e.target.value)}
                />
              </label>
              <label className="block text-sm font-semibold">
                Rider phone
                <input
                  className={`${inputCls} mt-1`}
                  inputMode="tel"
                  placeholder="Rider's phone number"
                  value={riderPhone}
                  onChange={(e) => setRiderPhone(e.target.value)}
                />
              </label>
              <PrimaryButton
                className="w-full py-3"
                disabled={busy !== "" || !riderName.trim() || !riderPhone.trim()}
                onClick={() =>
                  run("rider", () =>
                    updateRiderDetails(order.id, { riderName: riderName.trim(), riderPhone: riderPhone.trim() })
                  )
                }
              >
                {busy === "rider" ? "Saving…" : order.rider_name ? "Update rider details" : "Save rider details"}
              </PrimaryButton>
            </div>
          )}
          <p className="text-xs text-neutral-500">
            Live rider map arrives when a rider app is connected. For now you follow the
            steps above, the rider card and the delivery PIN below.
          </p>
        </section>
      )}

      {/* ---- Interstate: checkpoint stops timeline, no map ---- */}
      {isInterstate && order.delivery_method === "shipping" && (
        <section className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <h2 className="text-lg font-bold">Journey</h2>
          {lastCheckpoint ? (
            <p className="mt-2 inline-block rounded-full bg-brown px-3 py-1 text-sm font-semibold text-white">
              In Transit — Last stop: {lastCheckpoint.location || CHECKPOINT_LABELS[lastCheckpoint.status] || lastCheckpoint.status}, {timeAgo(lastCheckpoint.created_at)}
            </p>
          ) : order.status === "shipped" ? (
            <p className="mt-2 text-sm text-neutral-500">
              Shipped — waiting for the first stop update from the seller.
            </p>
          ) : (
            <p className="mt-2 text-sm text-neutral-500">
              Not shipped yet — the seller submits shipping proof once the money is held.
            </p>
          )}
          <p className="mt-3 text-xs text-neutral-500">
            Interstate parcels move through courier hubs, so you see checkpoint stops, not a
            live map. Delivery time depends on the courier and the distance — ask the seller
            in chat if you need a date.
          </p>
        </section>
      )}

      {/* ---- Courier + waybill (buyer + owner) ---- */}
      {(isBuyer || isOwner) && order.delivery_method === "shipping" && (
        <section className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <h2 className="text-lg font-bold">Courier</h2>
          <dl className="mt-2 space-y-1 text-sm">
            <div className="flex justify-between gap-2">
              <dt className="text-neutral-500">Courier</dt>
              <dd className="font-semibold">{order.courier || "Not chosen yet"}</dd>
            </div>
            <div className="flex justify-between gap-2">
              <dt className="text-neutral-500">Waybill number</dt>
              <dd className="font-semibold">{order.waybill_number || "Not submitted yet"}</dd>
            </div>
            {order.driver_phone && (
              <div className="flex justify-between gap-2">
                <dt className="text-neutral-500">Driver phone</dt>
                <dd className="font-semibold">
                  <a href={`tel:${order.driver_phone}`} className="text-brown underline">
                    {order.driver_phone}
                  </a>
                </dd>
              </div>
            )}
            {order.rider_phone && !isSameCity && (
              <div className="flex justify-between gap-2">
                <dt className="text-neutral-500">Rider phone</dt>
                <dd className="font-semibold">
                  <a href={`tel:${order.rider_phone}`} className="text-brown underline">
                    {order.rider_phone}
                  </a>
                </dd>
              </div>
            )}
            <div className="flex justify-between gap-2">
              <dt className="text-neutral-500">Shipping fee</dt>
              <dd className="font-semibold">{formatNaira(order.shipping_fee)}</dd>
            </div>
          </dl>
          {order.waybill_number && (
            <div className="mt-3">
              <GhostButton
                onClick={() =>
                  copyText(order.waybill_number, (ok) =>
                    setCopied(ok ? "Waybill number copied." : "Copy failed — the number is " + order.waybill_number)
                  )
                }
              >
                Copy waybill number
              </GhostButton>
              {copied && <span className="ml-2 text-sm text-neutral-500">{copied}</span>}
            </div>
          )}
        </section>
      )}

      {/* ---- Delivery PIN — buyer only ---- */}
      {isBuyer && order.delivery_pin && ["shipped", "delivered"].includes(order.status) && (
        <section className="rounded-2xl border border-brown bg-brown-soft p-4 text-center">
          <h2 className="text-lg font-bold">Delivery PIN</h2>
          <p className="mt-2 text-4xl font-bold tracking-[0.3em]">{order.delivery_pin}</p>
          <p className="mt-2 text-sm">Share this PIN with the courier at handover.</p>
          <p className="mt-1 text-xs text-neutral-500">
            The courier says the PIN back to you, or you type it below to confirm delivery.
          </p>
        </section>
      )}

      {/* ---- Confirm delivery with PIN (buyer) ---- */}
      {isBuyer && order.status === "shipped" && !order.frozen && (
        <section className="space-y-2 rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <h2 className="text-lg font-bold">Confirm delivery with PIN</h2>
          <p className="text-sm text-neutral-500">
            Only confirm when the item is in your hands and you have checked it. A wrong PIN
            confirms nothing.
          </p>
          <p className="text-sm text-neutral-500">
            You also need your unboxing video first — delivery only confirms with a verified
            unboxing video recorded in the app.{" "}
            <Link to="/evidence" className="font-semibold text-brown underline">
              Record it in the Evidence Locker
            </Link>
            .
          </p>
          <input
            className={inputCls}
            inputMode="numeric"
            maxLength={6}
            placeholder="Enter the 6-digit delivery PIN"
            value={pinInput}
            onChange={(e) => setPinInput(e.target.value.replace(/[^0-9]/g, "").slice(0, 6))}
          />
          <PrimaryButton
            className="w-full py-3"
            disabled={busy !== "" || pinInput.length !== 6 || unboxingMissing}
            onClick={() =>
              run("pin", () => confirmDeliveryWithPin(order.id, pinInput, user.id), () => setPinInput(""))
            }
          >
            {busy === "pin" ? "Checking…" : "Confirm delivery — I received the item"}
          </PrimaryButton>
          {evidenceFailed && (
            <p className="text-sm text-neutral-500">
              Could not check your unboxing video — the check itself failed.{" "}
              <button type="button" className="font-semibold text-brown underline" onClick={() => load()}>
                Check again
              </button>
            </p>
          )}
          {unboxingMissing && (
            <p className="text-sm text-neutral-500">
              Record your unboxing video in the{" "}
              <Link to="/evidence" className="font-semibold text-brown underline">
                Evidence Locker
              </Link>{" "}
              first — the button unlocks once it is verified.
            </p>
          )}
        </section>
      )}

      {/* ---- Checkpoint timeline (everyone on the order) ---- */}
      <section className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        <h2 className="text-lg font-bold">Stops</h2>
        {checkpoints.length === 0 ? (
          <p className="mt-2 text-sm text-neutral-500">No stops recorded yet.</p>
        ) : (
          <ol className="mt-2 space-y-3">
            {[...checkpoints].reverse().map((c) => (
              <li key={c.id} className="border-l-2 border-brown pl-3">
                <p className="text-sm font-semibold">
                  {CHECKPOINT_LABELS[c.status] || c.status}
                  {c.location ? <span className="font-normal text-neutral-500"> · {c.location}</span> : null}
                </p>
                <p className="text-xs text-neutral-500">{timeAgo(c.created_at)}</p>
                {c.note && <p className="mt-1 text-sm">{c.note}</p>}
                {c.photo && (
                  <a href={signedPhotoUrls.get(c.photo) || c.photo} target="_blank" rel="noreferrer" className="text-sm font-semibold text-brown underline">
                    View photo
                  </a>
                )}
              </li>
            ))}
          </ol>
        )}
      </section>

      {/* ---- Seller: shipping proof (Waybill Snap) ---- */}
      {isSeller && order.delivery_method === "shipping" && (
        <section className="space-y-3 rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <h2 className="text-lg font-bold">Shipping proof</h2>
          {showProofForm ? (
            <>
              <div className="rounded-xl border border-brown/40 bg-brown-soft p-3 text-sm">
                <p className="font-bold">{tiers.label}</p>
                <p className="mt-1">{tiers.note}</p>
                <p className="mt-1">
                  Allowed for this item: {tiers.allowedCouriers.join(", ")}.
                </p>
                {!courierAllowed && order.courier && (
                  <p className="mt-1 font-semibold">
                    This order's courier ({order.courier}) is outside the tier for this item
                    price — tell the PulseMarket team before you ship.
                  </p>
                )}
                <p className="mt-1">
                  Bus Park Waybill is always possible as a fallback, but a park loader with
                  only a driver phone and no receipt never earns the 50% shipping advance.
                </p>
              </div>

              <p className="text-sm font-semibold">Proof Complete checklist</p>
              <ul className="space-y-1">
                <Check done={proofChecklist.waybillNumber} label="Waybill number typed in" />
                <Check done={proofChecklist.waybillPhoto} label="Waybill photo taken" />
                <Check
                  done={proofChecklist.receiptPhoto}
                  label="Receipt photo taken"
                  hint="Needed for the 50% shipping advance — no receipt photo, no advance."
                />
                <Check done={false} label={PACKING_VIDEO_NOTE} hint="Not counted toward proof yet." />
              </ul>
              <p className="text-xs text-neutral-500">
                Waybill Snap is guided capture only: photograph the paper waybill and type the
                number in yourself. There is no OCR and nothing is auto-filled.
              </p>

              <label className="block text-sm font-semibold">
                Waybill number
                <input
                  className={`${inputCls} mt-1`}
                  placeholder="e.g. GIG123456789"
                  maxLength={64}
                  value={waybillNumber}
                  onChange={(e) => setWaybillNumber(e.target.value)}
                />
              </label>

              <label className="block text-sm font-semibold">
                Waybill photo — hold the paper steady, good light, all four corners visible
                <input
                  type="file"
                  accept="image/*"
                  capture="environment"
                  className={`${inputCls} mt-1`}
                  onChange={(e) => onPhotoInput(e, setWaybillPhoto)}
                />
              </label>
              {waybillPhoto && (
                <img src={waybillPhoto} alt="Waybill preview" className="max-h-48 rounded-xl border border-neutral-200" />
              )}

              <label className="block text-sm font-semibold">
                Receipt photo (needed for the 50% advance)
                <input
                  type="file"
                  accept="image/*"
                  capture="environment"
                  className={`${inputCls} mt-1`}
                  onChange={(e) => onPhotoInput(e, setReceiptPhoto)}
                />
              </label>
              {receiptPhoto && (
                <img src={receiptPhoto} alt="Receipt preview" className="max-h-48 rounded-xl border border-neutral-200" />
              )}

              <label className="block text-sm font-semibold">
                Driver phone (optional — bus-park waybills)
                <input
                  className={`${inputCls} mt-1`}
                  inputMode="tel"
                  placeholder="Driver's phone number"
                  value={driverPhone}
                  onChange={(e) => setDriverPhone(e.target.value)}
                />
              </label>

              <p className="text-sm text-neutral-500">
                Courier: <span className="font-semibold text-neutral-900 dark:text-white">{order.courier || "Not chosen yet"}</span>
                {order.courier && courierEarnsAdvance(order.courier)
                  ? " — this courier can earn the 50% shipping advance with a complete proof."
                  : " — this courier does not earn the 50% shipping advance."}
              </p>

              <PrimaryButton
                className="w-full py-3"
                disabled={busy !== "" || !waybillNumber.trim() || !waybillPhoto}
                onClick={() => {
                  if (!proofReady()) return;
                  run(
                    "proof",
                    () =>
                      submitShippingProof(order.id, {
                        waybillNumber: waybillNumber.trim(),
                        waybillPhoto,
                        receiptPhoto,
                        driverPhone: driverPhone.trim(),
                      }),
                    () => {
                      setWaybillNumber("");
                      setWaybillPhoto(null);
                      setReceiptPhoto(null);
                      setDriverPhone("");
                    }
                  );
                }}
              >
                {busy === "proof" ? "Submitting…" : "Submit shipping proof"}
              </PrimaryButton>
            </>
          ) : order.status === "shipped" || order.status === "delivered" || order.status === "released" ? (
            <div className="text-sm">
              <p>
                Proof submitted {order.shipping_proof_at ? timeAgo(order.shipping_proof_at) : ""}.
                Waybill: <span className="font-semibold">{order.waybill_number || "—"}</span>
              </p>
              <p className="mt-1 text-neutral-500">
                {order.shipping_advance_released
                  ? "The 50% shipping advance was released to your available balance."
                  : "No shipping advance was released for this proof — the full shipping fee is released when the buyer confirms delivery."}
              </p>
              {["shipped", "delivered"].includes(order.status) &&
                !order.shipping_advance_released &&
                order.waybill_number &&
                order.receipt_photo &&
                courierEarnsAdvance(order.courier) && (
                  <div className="mt-3">
                    <PrimaryButton
                      disabled={busy !== ""}
                      onClick={() => run("advance", () => retryShippingAdvance(order.id))}
                    >
                      {busy === "advance" ? "Releasing…" : "Retry shipping advance — release my 50%"}
                    </PrimaryButton>
                    <p className="mt-1 text-xs text-neutral-500">
                      Your proof is complete, but the advance never moved — tap to release it now.
                    </p>
                  </div>
                )}
              <p className="mt-1 text-neutral-500">
                The delivery PIN is shown to the buyer on this page — they share it with the courier at handover.
              </p>
              {order.waybill_photo && (
                <p className="mt-2">
                  <a href={signedPhotoUrls.get(order.waybill_photo) || order.waybill_photo} target="_blank" rel="noreferrer" className="font-semibold text-brown underline">
                    View waybill photo
                  </a>
                </p>
              )}
              {order.receipt_photo && (
                <p className="mt-1">
                  <a href={signedPhotoUrls.get(order.receipt_photo) || order.receipt_photo} target="_blank" rel="noreferrer" className="font-semibold text-brown underline">
                    View receipt photo
                  </a>
                </p>
              )}
            </div>
          ) : (
            <p className="text-sm text-neutral-500">
              Shipping proof opens once the buyer's money is held (order status "held").
              Current status: {order.status}.
            </p>
          )}
        </section>
      )}

      {/* ---- Seller: add checkpoint ---- */}
      {showCheckpointForm && (
        <section className="space-y-3 rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <h2 className="text-lg font-bold">Add a stop</h2>
          <label className="block text-sm font-semibold">
            Status
            <select className={`${inputCls} mt-1`} value={cpStatus} onChange={(e) => setCpStatus(e.target.value)}>
              {CHECKPOINT_STATUSES.map((s) => (
                <option key={s.value} value={s.value}>
                  {s.label}
                </option>
              ))}
            </select>
          </label>
          <label className="block text-sm font-semibold">
            Location
            <input
              className={`${inputCls} mt-1`}
              placeholder="e.g. Onitsha park, GIG terminal Port Harcourt"
              maxLength={120}
              value={cpLocation}
              onChange={(e) => setCpLocation(e.target.value)}
            />
          </label>
          <label className="block text-sm font-semibold">
            Note (optional)
            <input
              className={`${inputCls} mt-1`}
              placeholder="Anything the buyer should know"
              maxLength={280}
              value={cpNote}
              onChange={(e) => setCpNote(e.target.value)}
            />
          </label>
          <label className="block text-sm font-semibold">
            Photo (optional)
            <input
              type="file"
              accept="image/*"
              capture="environment"
              className={`${inputCls} mt-1`}
              onChange={(e) => onPhotoInput(e, setCpPhoto)}
            />
          </label>
          <PrimaryButton
            className="w-full py-3"
            disabled={busy !== ""}
            onClick={() => {
              if (!checkpointReady()) return;
              run(
                "checkpoint",
                () => addCheckpoint(order.id, { status: cpStatus, location: cpLocation.trim(), note: cpNote.trim(), photo: cpPhoto }),
                () => {
                  setCpLocation("");
                  setCpNote("");
                  setCpPhoto(null);
                }
              );
            }}
          >
            {busy === "checkpoint" ? "Adding…" : "Add stop"}
          </PrimaryButton>
        </section>
      )}

      {/* ---- Returns (buyer) ---- */}
      {/* Cash orders have no held money to refund, so the return form
          would always fail in openReturn() — cash returns are sorted
          out with the seller directly. */}
      {isBuyer && ["shipped", "delivered"].includes(order.status) && !order.frozen && order.return_status !== "opened" && order.return_status !== "resolved" && order.payment_method === "cash" && (
        <section className="space-y-3 rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <h2 className="text-lg font-bold">Open a return</h2>
          <p className="text-sm text-neutral-500">
            This was a cash order — there is no held money to refund, so returns are sorted out with the seller directly.
          </p>
        </section>
      )}
      {isBuyer && order.delivery_method === "shipping" && ["shipped", "delivered"].includes(order.status) && !order.frozen && order.return_status !== "opened" && order.return_status !== "resolved" && order.payment_method !== "cash" && (
        <section className="space-y-3 rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <h2 className="text-lg font-bold">Open a return</h2>
          <p className="text-sm text-neutral-500">
            If the item is wrong, damaged, not as described or fake, the seller is at fault:
            you get the full total back — item price + shipping + fees — and the seller pays the return shipping.
            If you simply changed your mind, you get the item price back only, the seller
            keeps the shipping money, and you pay the return shipping. The PulseMarket team
            decides after looking at the evidence — email {OWNER_EMAIL} if you need help.
          </p>
          <label className="block text-sm font-semibold">
            Reason
            <select className={`${inputCls} mt-1`} value={returnReason} onChange={(e) => setReturnReason(e.target.value)}>
              {RETURN_REASONS.map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
          </label>
          <div className="space-y-2 text-sm">
            <label className="flex items-center gap-2">
              <input type="radio" name="return-fault" checked={returnFault === "seller"} onChange={() => setReturnFault("seller")} />
              Seller's fault — wrong, damaged, not as described, or fake
            </label>
            <label className="flex items-center gap-2">
              <input type="radio" name="return-fault" checked={returnFault === "buyer"} onChange={() => setReturnFault("buyer")} />
              My fault — I changed my mind
            </label>
          </div>
          <GhostButton
            className="w-full py-3"
            disabled={busy !== ""}
            onClick={() => run("return", () => openReturn(order.id, { reason: returnReason, fault: returnFault }))}
          >
            {busy === "return" ? "Opening…" : "Open return"}
          </GhostButton>
        </section>
      )}

      {order.return_status === "opened" && (
        <section className="rounded-2xl border border-brown bg-brown-soft p-4">
          <h2 className="text-lg font-bold">Return open</h2>
          <p className="mt-1 text-sm">{order.return_reason || "A return is open for this order."}</p>
          <p className="mt-1 text-sm text-neutral-500">
            The PulseMarket team will resolve it after looking at the evidence.
          </p>
          {isBuyer && (
            <p className="mt-1 text-sm">
              Before the team can refund you, they need proof the item came back — record a return photo in the{" "}
              <Link to="/evidence" className="font-semibold text-brown underline">
                Evidence Locker
              </Link>
              .
            </p>
          )}
          {isOwner && (
            <div className="mt-3 flex flex-col gap-2">
              <PrimaryButton
                disabled={busy !== ""}
                onClick={() => run("resolve-seller", () => resolveReturn(order.id, { fault: "seller", attested: returnAttested }))}
              >
                {busy === "resolve-seller" ? "Resolving…" : "Resolve — seller fault (full refund to buyer)"}
              </PrimaryButton>
              <PrimaryButton
                disabled={busy !== ""}
                onClick={() => run("resolve-buyer", () => resolveReturn(order.id, { fault: "buyer", attested: returnAttested }))}
              >
                {busy === "resolve-buyer" ? "Resolving…" : "Resolve — buyer fault (item price only)"}
              </PrimaryButton>
              <label className="flex items-start gap-2 text-sm">
                <input
                  type="checkbox"
                  className="mt-1"
                  checked={returnAttested}
                  onChange={(e) => setReturnAttested(e.target.checked)}
                />
                <span>
                  I have seen the item come back myself (no return photo on file) — resolving without a verified return photo.
                </span>
              </label>
              <GhostButton
                disabled={busy !== ""}
                onClick={() => run("reject-return", () => rejectReturn(order.id))}
              >
                {busy === "reject-return" ? "Rejecting…" : "Reject return — the claim does not hold up"}
              </GhostButton>
            </div>
          )}
        </section>
      )}

      <p className="text-xs text-neutral-400">
        Tracking for order {order.code}. Support: {OWNER_EMAIL}
      </p>
    </div>
  );
}
