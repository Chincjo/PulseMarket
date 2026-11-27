// Milestone 7 — Face-to-face handoff (route /handoff/:orderId, added
// by the coordinator). The seller shows their one-time code BIG plus a
// QR code made on their own phone (the `qrcode` package — no external
// QR service, no data leaves the device). The buyer types the code they
// see on the seller's phone — the "Scan with camera" button opens the
// in-app camera so they can photograph the seller's QR code and read
// the code from it; there is no live QR decoder, so nothing here
// pretends to scan. Both sides take a handover photo with the in-app
// camera and confirm. Only when both have confirmed can the money be
// released (see the gates in src/lib/orders.js).
import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import QRCode from "qrcode";
import { fetchListing } from "../lib/listings";
import { fetchOrder } from "../lib/orders";
import {
  confirmHandoff,
  ensureSellerCode,
  getHandoffStatus,
  scanSellerCode,
  uploadHandoffPhoto,
} from "../lib/handoff";
import { OWNER_EMAIL } from "../lib/payments";
import { useAuth } from "../lib/auth";
import { EmptyState, GhostButton, PrimaryButton, inputCls } from "../components/ui";

function Check({ done, label }) {
  return (
    <li className="flex items-center gap-2 text-sm">
      <span
        className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-xs font-bold ${
          done ? "bg-brown text-white" : "border border-neutral-300 text-neutral-400 dark:border-neutral-700"
        }`}
      >
        {done ? "✓" : "·"}
      </span>
      <span className={done ? "font-semibold" : "text-neutral-500"}>{label}</span>
    </li>
  );
}

function fileToDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error("Could not read that photo. Try again."));
    reader.readAsDataURL(file);
  });
}

export default function Handoff() {
  const { orderId } = useParams();
  const { user } = useAuth();
  const [order, setOrder] = useState(null);
  const [listing, setListing] = useState(null);
  const [status, setStatus] = useState(null);
  const [qrUrl, setQrUrl] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState("");
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const [codeInput, setCodeInput] = useState("");
  const [scanPhoto, setScanPhoto] = useState("");
  const [myPhotoPreview, setMyPhotoPreview] = useState("");
  const photoInputRef = useRef(null);
  const scanInputRef = useRef(null);

  const isBuyer = user && order && order.buyer_id === user.id;
  const isSeller = user && order && order.seller_id === user.id;
  const role = isBuyer ? "buyer" : isSeller ? "seller" : null;

  const load = useCallback(async () => {
    try {
      const row = await fetchOrder(orderId);
      setOrder(row);
      if (row) {
        const item = await fetchListing(row.listing_id);
        setListing(item);
        // Seller opening the handoff creates the one-time code —
        // unless the order is frozen (open dispute): no handoff
        // activity may start while the team is reviewing.
        let current = row;
        if (user && row.seller_id === user.id && row.delivery_method === "meetup" && !row.seller_code && !row.handoff_locked && !row.frozen) {
          try {
            current = await ensureSellerCode(row.id);
            setOrder(current);
          } catch (err) {
            setError(err?.message || "Could not create the seller code.");
          }
        }
        const st = await getHandoffStatus(current.id);
        setStatus(st);
        if (current.seller_code) {
          try {
            setQrUrl(await QRCode.toDataURL(current.seller_code, { width: 240, margin: 1 }));
          } catch {
            setQrUrl("");
          }
        }
      }
    } catch (err) {
      setError(err?.message || "Could not load this handoff. Try again.");
    } finally {
      setLoading(false);
    }
  }, [orderId, user]);

  useEffect(() => {
    load();
  }, [load]);

  async function run(action, fn) {
    setError("");
    setNotice("");
    setBusy(action);
    try {
      const updated = await fn();
      if (updated) setOrder(updated);
      const st = await getHandoffStatus(orderId);
      setStatus(st);
      if (st?.code) {
        try {
          setQrUrl(await QRCode.toDataURL(st.code, { width: 240, margin: 1 }));
        } catch {
          setQrUrl("");
        }
      }
      setNotice("Done.");
    } catch (err) {
      setError(err?.message || "Something went wrong. Please try again.");
    } finally {
      setBusy("");
    }
  }

  async function onPhotoFile(file) {
    if (!file || !role) return;
    // A multi-megabyte photo becomes a giant data URL and a giant
    // upload — refuse it plainly instead of hanging the save.
    if (file.size > 10 * 1024 * 1024) {
      setError("That photo is too big — keep handover photos under 10MB.");
      return;
    }
    setError("");
    setNotice("");
    setBusy("photo");
    try {
      const dataUrl = await fileToDataUrl(file);
      setMyPhotoPreview(dataUrl);
      await uploadHandoffPhoto(orderId, role, dataUrl);
      const st = await getHandoffStatus(orderId);
      setStatus(st);
      setNotice("Photo saved.");
    } catch (err) {
      setError(err?.message || "Could not save the photo. Try again.");
    } finally {
      setBusy("");
    }
  }

  async function onScanFile(file) {
    if (!file) return;
    if (file.size > 10 * 1024 * 1024) {
      setError("That photo is too big — take a smaller one (under 10MB).");
      return;
    }
    try {
      setScanPhoto(await fileToDataUrl(file));
      setNotice("Photo taken — read the code on the seller's phone and type it below.");
    } catch {
      setError("Could not read that photo. Type the code instead.");
    }
  }

  if (loading) {
    return <p className="py-10 text-center text-sm text-neutral-500">Loading handoff…</p>;
  }
  if (!order) {
    return (
      <EmptyState
        title="Order not found"
        body="It may have been removed, or the handoff tables have not been switched on yet."
        action={
          <Link to="/dashboard">
            <GhostButton>Back to dashboard</GhostButton>
          </Link>
        }
      />
    );
  }
  if (!role) {
    return (
      <EmptyState
        title="Not your handoff"
        body="Only the buyer and the seller of this order can open its handoff."
        action={
          <Link to={`/order/${order.id}`}>
            <GhostButton>Back to order</GhostButton>
          </Link>
        }
      />
    );
  }
  // "released" belongs here too: the money has already moved, so
  // there is no handoff left to do — without it a released order
  // rendered the whole handoff UI and the seller-code creation
  // attempt failed with "This order is closed" on top of it.
  if (["cancelled", "refunded", "released"].includes(order.status)) {
    return (
      <div className="space-y-5">
        <Link to={`/order/${order.id}`} className="text-sm font-semibold text-brown">
          ← Back to order
        </Link>
        <EmptyState
          title="This order is closed"
          body={`This order is ${order.status}, so there is no handoff left to do.`}
        />
      </div>
    );
  }
  if (order.delivery_method !== "meetup") {
    return (
      <div className="space-y-5">
        <Link to={`/order/${order.id}`} className="text-sm font-semibold text-brown">
          ← Back to order
        </Link>
        <EmptyState
          title="No handoff for this order"
          body="This order is being shipped, so there is no face-to-face handoff. The seller code is only for meet-in-person orders."
        />
      </div>
    );
  }

  const locked = status?.locked;
  const frozen = Boolean(order?.frozen);
  const complete = status?.releaseUnblocked;
  const myPhotoUrl = role === "buyer" ? status?.buyerPhotoUrl : status?.sellerPhotoUrl;
  const myPhotoDone = role === "buyer" ? status?.buyerPhoto : status?.sellerPhoto;
  const myConfirmed = role === "buyer" ? status?.buyerConfirmed : status?.sellerConfirmed;
  const otherConfirmed = role === "buyer" ? status?.sellerConfirmed : status?.buyerConfirmed;
  const canConfirm = status?.scanned && myPhotoDone && !myConfirmed;

  return (
    <div className="space-y-5">
      <Link to={`/order/${order.id}`} className="text-sm font-semibold text-brown">
        ← Back to order
      </Link>
      <div>
        <h1 className="text-2xl font-bold">Meet-in-person handoff</h1>
        <p className="mt-1 text-sm text-neutral-500">
          {listing?.title || "Item"} · {order.meetup_spot || "meetup spot to be agreed"}
        </p>
        <p className="text-sm text-neutral-500">
          Order {order.code} · You are the {role}.
        </p>
      </div>

      {frozen && (
        <section className="rounded-2xl border border-red-300 bg-red-50 p-4 dark:border-red-900 dark:bg-red-950">
          <h2 className="text-lg font-bold text-red-700 dark:text-red-300">A dispute is open for this order</h2>
          <p className="mt-1 text-sm">
            The money is frozen while the PulseMarket team reviews it — the
            handoff is paused until then. Do not scan the code or confirm
            anything here; the team will tell you what happens next.
          </p>
        </section>
      )}

      {locked && (
        <section className="rounded-2xl border border-red-300 bg-red-50 p-4 dark:border-red-900 dark:bg-red-950">
          <h2 className="text-lg font-bold text-red-700 dark:text-red-300">This handoff is locked</h2>
          <p className="mt-1 text-sm">
            Too many wrong codes were entered. For your safety the handoff
            cannot continue here — contact the PulseMarket team at{" "}
            <span className="font-semibold underline">{OWNER_EMAIL}</span> and
            quote order {order.code}.
          </p>
        </section>
      )}

      {complete && !locked && (
        <section className="rounded-2xl border border-brown bg-brown-soft p-4">
          <h2 className="text-lg font-bold">Handoff complete — money can now be released</h2>
          <p className="mt-1 text-sm">
            The code was scanned, both photos were taken and both sides
            confirmed. The buyer can now confirm delivery and release the
            held money to the seller.
          </p>
          <div className="mt-3">
            <Link to={`/order/${order.id}`}>
              <PrimaryButton>Go to the order</PrimaryButton>
            </Link>
          </div>
        </section>
      )}

      {/* Seller: show the code + QR */}
      {isSeller && (
        <section className="rounded-2xl border border-neutral-200 p-4 text-center dark:border-neutral-800">
          <h2 className="text-lg font-bold">Your seller code</h2>
          <p className="mt-1 text-sm text-neutral-500">
            Show this to the buyer at the meetup. They scan it or type it in.
            The code works once, for this deal only.
          </p>
          {status?.code ? (
            <>
              <p className="mt-3 inline-block rounded-xl bg-neutral-100 px-4 py-2 text-3xl font-bold tracking-widest dark:bg-neutral-900">
                {status.code}
              </p>
              {qrUrl && (
                <div className="mt-3 flex justify-center">
                  <img src={qrUrl} alt={`QR code for seller code ${status.code}`} className="h-60 w-60 rounded-xl border border-neutral-200 bg-white p-2 dark:border-neutral-800" />
                </div>
              )}
              <p className="mt-2 text-xs text-neutral-500">
                The QR code is made on your phone — it is never sent anywhere.
              </p>
            </>
          ) : (
            <p className="mt-3 text-sm text-neutral-500">
              {locked ? "No code — this handoff is locked." : "Creating your code…"}
            </p>
          )}
        </section>
      )}

      {/* Buyer: scan / type the code */}
      {isBuyer && (
        <section className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <h2 className="text-lg font-bold">Scan the seller code</h2>
          {status?.scanned ? (
            <p className="mt-1 text-sm font-semibold">
              Code scanned ✓ — the handoff is under way.
            </p>
          ) : (
            <>
              <p className="mt-1 text-sm text-neutral-500">
                Ask the seller to show their code (or the QR code on their
                phone) and type it here. {status?.attemptsLeft != null && status.attempts > 0
                  ? `${status.attemptsLeft} ${status.attemptsLeft === 1 ? "try" : "tries"} left before the handoff locks.`
                  : "5 wrong codes locks the handoff."}
              </p>
              <label className="mt-3 block text-sm font-semibold" htmlFor="seller-code">
                Seller code
              </label>
              <input
                id="seller-code"
                className={`${inputCls} mt-1 uppercase tracking-widest`}
                value={codeInput}
                onChange={(e) => setCodeInput(e.target.value.toUpperCase().replace(/[^A-Z0-9-]/g, ""))}
                placeholder="PM-XXXXXX"
                autoCapitalize="characters"
                autoComplete="off"
                disabled={locked || frozen || busy !== ""}
              />
              <div className="mt-3 flex gap-2">
                <PrimaryButton
                  disabled={locked || frozen || busy !== "" || !codeInput.trim()}
                  onClick={() => run("scan", () => scanSellerCode(orderId, codeInput))}
                >
                  {busy === "scan" ? "Checking…" : "Check code"}
                </PrimaryButton>
                <GhostButton
                  disabled={locked || frozen || busy !== ""}
                  onClick={() => scanInputRef.current?.click()}
                >
                  Photograph the QR code
                </GhostButton>
              </div>
              <p className="mt-2 text-xs text-neutral-500">
                The photo is not decoded — read the code on the seller's phone and type it in the box above.
              </p>
              <input
                ref={scanInputRef}
                type="file"
                accept="image/*"
                capture="environment"
                className="hidden"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) onScanFile(file);
                  e.target.value = "";
                }}
              />
              {scanPhoto && (
                <div className="mt-3">
                  <img src={scanPhoto} alt="Photo of the seller's QR code" className="max-h-48 rounded-xl border border-neutral-200 dark:border-neutral-800" />
                  <p className="mt-1 text-xs text-neutral-500">
                    Read the code from the seller's phone and type it above — the
                    photo itself is not decoded.
                  </p>
                </div>
              )}
            </>
          )}
        </section>
      )}

      {/* Photo step — both sides */}
      <section className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        <h2 className="text-lg font-bold">Handover photo</h2>
        <p className="mt-1 text-sm text-neutral-500">
          Take a photo of the handover with your camera — the item changing
          hands.
        </p>
        {(myPhotoPreview || myPhotoUrl) && (
          <img
            src={myPhotoPreview || myPhotoUrl}
            alt="Your handover photo"
            className="mt-3 max-h-56 rounded-xl border border-neutral-200 dark:border-neutral-800"
          />
        )}
        <div className="mt-3">
          <GhostButton
            disabled={busy !== "" || locked || frozen || myConfirmed}
            onClick={() => photoInputRef.current?.click()}
          >
            {busy === "photo"
              ? "Saving photo…"
              : myConfirmed
                ? "Photo locked — you already confirmed"
                : myPhotoDone
                  ? "Retake photo"
                  : "Take photo with camera"}
          </GhostButton>
        </div>
        <input
          ref={photoInputRef}
          type="file"
          accept="image/*"
          capture="environment"
          className="hidden"
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (file) onPhotoFile(file);
            e.target.value = "";
          }}
        />
        <p className="mt-2 text-xs text-neutral-500">
          {myPhotoDone ? "Your photo is saved." : "Your photo is needed before you can confirm."}
        </p>
      </section>

      {/* Dual confirm */}
      <section className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        <h2 className="text-lg font-bold">Confirm the handoff</h2>
        <ul className="mt-3 space-y-2">
          <Check done={status?.scanned} label="Buyer scanned the seller code" />
          <Check done={status?.buyerPhoto} label="Buyer took a handover photo" />
          <Check done={status?.sellerPhoto} label="Seller took a handover photo" />
          <Check done={status?.buyerConfirmed} label="Buyer confirmed" />
          <Check done={status?.sellerConfirmed} label="Seller confirmed" />
        </ul>
        {myConfirmed ? (
          <p className="mt-3 text-sm font-semibold">
            You confirmed. {otherConfirmed ? "Both sides confirmed." : "Waiting for the other side."}
          </p>
        ) : (
          <>
            <p className="mt-3 text-sm text-neutral-500">
              {!status?.scanned
                ? "The code must be scanned before anyone can confirm."
                : !myPhotoDone
                  ? "Take your handover photo before confirming."
                  : "Only confirm if you met in person and the handover really happened."}
            </p>
            <div className="mt-3">
              <PrimaryButton
                className="w-full py-3"
                disabled={busy !== "" || locked || frozen || !canConfirm}
                onClick={() => run("confirm", () => confirmHandoff(orderId, role))}
              >
                {busy === "confirm" ? "Saving…" : "I confirm — the handover happened"}
              </PrimaryButton>
            </div>
          </>
        )}
        {!complete && !myConfirmed && status?.scanned && (
          <p className="mt-2 text-xs text-neutral-500">Waiting for the other side — the handoff completes when both sides confirm.</p>
        )}
      </section>

      {notice && <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm dark:bg-neutral-900">{notice}</p>}
      {error && <p className="rounded-xl bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}

      <p className="text-xs text-neutral-400">
        Handoff for order {order.code}. Something wrong? Support: {OWNER_EMAIL}
      </p>
    </div>
  );
}
