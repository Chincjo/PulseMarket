// Milestone 6 — Checkout (route /checkout/:listingId, added by the
// coordinator). Manual escrow: cash is paid face to face with no fees;
// "pay through the app" is a bank transfer to PulseMarket, held until
// the buyer confirms delivery. No payment provider is wired in.
import { useEffect, useMemo, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { SAFE_MEETUP_SPOTS, STATES } from "../lib/data";
import { feeBreakdown, formatNaira } from "../lib/fees";
import { fetchListing, fetchVerificationRow } from "../lib/listings";
import { universityState } from "../lib/data";
import { createOrder } from "../lib/orders";
import { OWNER_EMAIL, shippingZone } from "../lib/payments";
import { useAuth } from "../lib/auth";
import { EmptyState, GhostButton, PrimaryButton, inputCls } from "../components/ui";

const COURIERS = [
  "GIG Logistics",
  "GUO Transport",
  "Chowdeck Relay",
  "Peace Logistics",
  "ABC Transport",
  "DHL Domestic",
  "Bus Park Waybill",
];

export default function Checkout() {
  const { listingId } = useParams();
  const { user } = useAuth();
  const navigate = useNavigate();
  const [listing, setListing] = useState(null);
  const [loading, setLoading] = useState(true);
  const [buyerState, setBuyerState] = useState("");
  const [paymentMethod, setPaymentMethod] = useState("cash");
  const [deliveryMethod, setDeliveryMethod] = useState("meetup");
  const [meetupSpot, setMeetupSpot] = useState("");
  const [shipToState, setShipToState] = useState("");
  const [courier, setCourier] = useState("");
  const [reserving, setReserving] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fetchListing(listingId)
      .then((row) => {
        if (cancelled) return;
        setListing(row);
        setLoading(false);
        if (row) {
          setMeetupSpot(row.meetup_spot || SAFE_MEETUP_SPOTS[0]);
          setCourier(row.courier || COURIERS[0]);
          const methods = row.delivery_methods || [];
          if (!methods.includes("meetup") && methods.includes("shipping")) {
            setDeliveryMethod("shipping");
          }
        }
      })
      .catch(() => {
        if (!cancelled) {
          setListing(null);
          setLoading(false);
        }
      });
    if (user) {
      fetchVerificationRow(user.id).then((row) => {
        if (!cancelled && row?.university) {
          const state = universityState(row.university);
          setBuyerState(state);
          // Ship-to defaults to the buyer's university state, so the
          // shipping fee shown is for the state the parcel actually
          // goes to — the select used to sit blank on "Choose a
          // state…" while the summary already charged a fee.
          setShipToState((prev) => prev || state);
        }
      });
    }
    return () => {
      cancelled = true;
    };
  }, [listingId, user]);

  const fees = useMemo(
    () => (listing ? feeBreakdown(listing.price, paymentMethod) : null),
    [listing, paymentMethod]
  );
  // No destination, no shipping fee: pricing the fee from an empty
  // state used to charge the same-state ₦1,500 before the buyer had
  // picked anywhere — the total shown was for a trip that was never
  // chosen.
  const zone = useMemo(
    () =>
      deliveryMethod === "shipping" && listing && (shipToState || buyerState)
        ? shippingZone(shipToState || buyerState, listing.state)
        : null,
    [deliveryMethod, shipToState, buyerState, listing]
  );
  const shippingFee = zone ? zone.fee : 0;
  const total = fees ? fees.total + shippingFee : 0;

  // A listing with no delivery_methods on file (older rows) can be
  // bought either way — treating a missing field as "offers neither"
  // disabled both delivery buttons and left the buyer with no way
  // to check out at all.
  const deliveryMethods = listing?.delivery_methods;
  const canMeet = !listing || !deliveryMethods ? true : deliveryMethods.includes("meetup");
  // Shipping only when the seller actually offers it. The old check
  // also allowed shipping for any nationwide listing, so a meetup-only
  // listing could be ordered for shipping.
  const canShip = !listing || !deliveryMethods ? true : deliveryMethods.includes("shipping");
  // Chowdeck Relay is same-city only — it must never be offered for
  // shipping to another state.
  const courierOptions =
    shipToState && listing && shipToState !== listing.state
      ? COURIERS.filter((c) => c !== "Chowdeck Relay")
      : COURIERS;
  const effectiveCourier = courierOptions.includes(courier)
    ? courier
    : courierOptions[0];

  async function reserve() {
    if (!listing || !user) return;
    setError("");
    // Shipping with no destination state used to sail through and
    // silently fall back to the buyer's state (or none at all) —
    // the order then had nowhere to ship to.
    if (deliveryMethod === "shipping" && !shipToState && !buyerState) {
      setError("Choose the state to ship to.");
      return;
    }
    // Cash is paid face to face, so it needs a meetup — on a
    // shipping-only listing there is no cash path at all. Say so
    // before reserving instead of letting the server refuse it.
    if (paymentMethod === "cash" && !canMeet) {
      setError("This seller only ships — cash is paid face to face, so choose “Pay through the app” for this item.");
      return;
    }
    if (deliveryMethod === "meetup" && !meetupSpot) {
      setError("Choose a safe meetup spot.");
      return;
    }
    setReserving(true);
    try {
      const shipState = deliveryMethod === "shipping" ? shipToState || buyerState : null;
      // Chowdeck Relay is same-city only. The courier list already
      // drops it once a different state is picked, but when no
      // state was picked the ship-to state falls back to the
      // buyer's university state — which can be interstate — while
      // the courier stays Chowdeck. Force a tracked interstate
      // courier in that case instead of booking a same-city rider
      // for an interstate parcel.
      let finalCourier = effectiveCourier;
      if (
        deliveryMethod === "shipping" &&
        shipState &&
        listing &&
        shipState !== listing.state &&
        finalCourier === "Chowdeck Relay"
      ) {
        finalCourier = "GIG Logistics";
      }
      const order = await createOrder({
        listing,
        buyerId: user.id,
        paymentMethod,
        deliveryMethod,
        meetupSpot: deliveryMethod === "meetup" ? meetupSpot : null,
        shipToState: deliveryMethod === "shipping" ? shipToState || buyerState : null,
        courier: deliveryMethod === "shipping" ? finalCourier : null,
        buyerState,
      });
      navigate(`/order/${order.id}`);
    } catch (err) {
      setError(err?.message || "Could not reserve this item. Please try again.");
    } finally {
      setReserving(false);
    }
  }

  if (loading) {
    return <p className="py-10 text-center text-sm text-neutral-500">Loading checkout…</p>;
  }
  if (!listing) {
    return (
      <EmptyState
        title="Item not found"
        body="This listing may have been removed."
        action={
          <Link to="/search">
            <GhostButton>Back to search</GhostButton>
          </Link>
        }
      />
    );
  }
  if (listing.status !== "active") {
    return (
      <EmptyState
        title="This item is no longer available"
        body={`It is currently ${listing.status}.`}
        action={
          <Link to="/search">
            <GhostButton>Back to search</GhostButton>
          </Link>
        }
      />
    );
  }
  if (user && listing.seller_id === user.id) {
    return (
      <EmptyState
        title="This is your listing"
        body="You cannot buy your own item."
        action={
          <Link to={`/listing/${listing.id}`}>
            <GhostButton>View listing</GhostButton>
          </Link>
        }
      />
    );
  }

  return (
    <div className="space-y-5">
      <Link to={`/listing/${listing.id}`} className="text-sm font-semibold text-brown">
        ← Back to item
      </Link>
      <h1 className="text-2xl font-bold">Checkout</h1>

      <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        <p className="font-semibold">{listing.title}</p>
        <p className="text-sm text-neutral-500">
          {listing.seller_label} · {listing.state} · {listing.condition}
        </p>
        <p className="mt-1 text-lg font-bold">{formatNaira(listing.price)}</p>
      </div>

      <section className="space-y-2">
        <h2 className="text-lg font-bold">How do you want to pay?</h2>
        <div className="grid grid-cols-2 gap-2">
          <button
            type="button"
            onClick={() => {
              setPaymentMethod("cash");
              // Cash settles face to face, so it always means meeting in person —
              // unless the seller does not offer meetups at all, in which
              // case there is no cash path for this item.
              if (canMeet) setDeliveryMethod("meetup");
            }}
            className={`rounded-xl border px-3 py-3 text-left text-sm font-semibold ${
              paymentMethod === "cash" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"
            }`}
          >
            Cash — face to face
            <span className="block text-xs font-normal text-neutral-500">No fees. Pay the seller when you meet.</span>
          </button>
          <button
            type="button"
            onClick={() => setPaymentMethod("held")}
            className={`rounded-xl border px-3 py-3 text-left text-sm font-semibold ${
              paymentMethod === "held" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"
            }`}
          >
            Pay through the app (held)
            <span className="block text-xs font-normal text-neutral-500">Bank transfer to PulseMarket. Held until you confirm.</span>
          </button>
        </div>
        {paymentMethod === "cash" && !canMeet && (
          <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm text-neutral-600 dark:bg-neutral-900">
            Cash is paid face to face, but this seller only ships — choose “Pay through the app” above to buy this item.
          </p>
        )}
        {paymentMethod === "held" && (
          <p className="rounded-xl bg-neutral-100 px-3 py-2 text-sm text-neutral-600 dark:bg-neutral-900">
            Your money is HELD by PulseMarket until you confirm you received the item
            (with photo/video). If you do not confirm within 48 hours of delivery, it
            is released to the seller automatically. The seller keeps the full item
            price — the fees below are paid by you.
          </p>
        )}
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-bold">How do you want to get it?</h2>
        <div className="grid grid-cols-2 gap-2">
          <button
            type="button"
            disabled={!canMeet}
            onClick={() => setDeliveryMethod("meetup")}
            className={`rounded-xl border px-3 py-3 text-left text-sm font-semibold disabled:opacity-40 ${
              deliveryMethod === "meetup" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"
            }`}
          >
            Meet in person
            <span className="block text-xs font-normal text-neutral-500">At a safe spot on campus.</span>
          </button>
          <button
            type="button"
            disabled={!canShip || paymentMethod === "cash"}
            onClick={() => setDeliveryMethod("shipping")}
            className={`rounded-xl border px-3 py-3 text-left text-sm font-semibold disabled:opacity-40 ${
              deliveryMethod === "shipping" ? "border-brown bg-brown-soft" : "border-neutral-300 dark:border-neutral-700"
            }`}
          >
            Ship it
            <span className="block text-xs font-normal text-neutral-500">GIG / GUO between states, Chowdeck Relay same-city.</span>
          </button>
        </div>
        {deliveryMethod === "meetup" && (
          <label className="block text-sm font-semibold">
            Safe meetup spot
            <select value={meetupSpot} onChange={(e) => setMeetupSpot(e.target.value)} className={`${inputCls} mt-1`}>
              {SAFE_MEETUP_SPOTS.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
          </label>
        )}
        {deliveryMethod === "shipping" && (
          <div className="space-y-2">
            <label className="block text-sm font-semibold">
              Ship to (state)
              <select
                value={shipToState}
                onChange={(e) => {
                  setShipToState(e.target.value);
                  // Leaving the seller's state drops Chowdeck Relay
                  // (same-city only) from the courier list.
                  if (
                    e.target.value &&
                    listing &&
                    e.target.value !== listing.state &&
                    courier === "Chowdeck Relay"
                  ) {
                    setCourier("GIG Logistics");
                  }
                }}
                className={`${inputCls} mt-1`}
              >
                <option value="">Choose a state…</option>
                {STATES.map((s) => (
                  <option key={s} value={s}>
                    {s}
                  </option>
                ))}
              </select>
            </label>
            <label className="block text-sm font-semibold">
              Courier
              <select value={effectiveCourier} onChange={(e) => setCourier(e.target.value)} className={`${inputCls} mt-1`}>
                {courierOptions.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </label>
            {zone && (
              <p className="text-sm text-neutral-500">
                Shipping zone: {zone.label} — {formatNaira(zone.fee)}
                {zone.isEstimate ? " (estimate — the exact fee is confirmed when the parcel is booked)" : ""}
              </p>
            )}
          </div>
        )}
      </section>

      <section className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        <h2 className="text-lg font-bold">Summary</h2>
        <dl className="mt-2 space-y-1 text-sm">
          <div className="flex justify-between">
            <dt>Item price</dt>
            <dd className="font-semibold">{formatNaira(fees.price)}</dd>
          </div>
          <div className="flex justify-between">
            <dt>
              Service fee{" "}
              {paymentMethod === "cash"
                ? "(cash — no fee)"
                : listing.price < 5000
                  ? "(flat ₦150 under ₦5,000)"
                  : "(5%, capped at ₦2,000)"}
            </dt>
            <dd className="font-semibold">{formatNaira(fees.serviceFee)}</dd>
          </div>
          <div className="flex justify-between">
            <dt>
              Secure payment fee{" "}
              {paymentMethod === "cash" ? "(cash — no fee)" : "(1.5% + ₦100)"}
            </dt>
            <dd className="font-semibold">{formatNaira(fees.secureFee)}</dd>
          </div>
          <div className="flex justify-between">
            <dt>Shipping {zone?.isEstimate ? "(estimate)" : ""}</dt>
            <dd className="font-semibold">
              {deliveryMethod === "shipping" && !zone ? "—" : formatNaira(shippingFee)}
            </dd>
          </div>
          <div className="flex justify-between border-t border-neutral-200 pt-2 text-base font-bold dark:border-neutral-800">
            <dt>Total to pay</dt>
            <dd>{formatNaira(total)}</dd>
          </div>
        </dl>
        <p className="mt-2 text-xs text-neutral-500">
          {paymentMethod === "cash"
            ? "Cash face-to-face deals have no fees — you pay the seller the item price when you meet."
            : "The seller keeps the full item price. The service and secure fees are yours as the buyer."}
        </p>
        {deliveryMethod === "shipping" && !zone && (
          <p className="mt-2 text-xs text-neutral-500">
            Choose the state to ship to above — the shipping fee and total will update.
          </p>
        )}
      </section>

      {error && <p className="rounded-xl bg-red-50 px-3 py-2 text-sm text-red-700">{error}</p>}

      <PrimaryButton onClick={reserve} disabled={reserving || !user || (paymentMethod === "cash" && !canMeet)} className="w-full py-3 text-base">
        {reserving ? "Reserving…" : "Reserve — Put on Hold"}
      </PrimaryButton>
      <p className="text-center text-xs text-neutral-500">
        Reserving holds this item for you. {paymentMethod === "cash" ? "You pay nothing now." : "You will get the transfer instructions on the next screen — the PulseMarket team shares the account details by email."}
        Questions? {OWNER_EMAIL}
      </p>
    </div>
  );
}
