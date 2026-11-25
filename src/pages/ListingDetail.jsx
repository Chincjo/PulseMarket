// Listing detail — photos, seller card, delivery, automatic fee breakdown,
// watchlist save, and boost (owner only). Chat and Make Offer arrive with
// the next build, so this page says so honestly instead of a dead button.
import { useEffect, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { SHIPPING_ZONES } from "../lib/data";
import { feeBreakdown, formatNaira } from "../lib/fees";
import {
  BOOST_TIERS,
  boostListing,
  bumpViews,
  deleteListing,
  duplicateListing,
  fetchListing,
  fetchWatchlistIds,
  isBoosted,
  setWatchlisted,
  updateListing,
} from "../lib/listings";
import { EmptyState, GhostButton, PrimaryButton } from "../components/ui";
import { BoostedBadge } from "../components/ListingCard";
import ListingEditForm from "../components/ListingEditForm";
import { startConversation } from "../lib/chat";
import { fetchSellerRating } from "../lib/ratings";
import { useAuth } from "../lib/auth";

export default function ListingDetail() {
  const { id } = useParams();
  const { user } = useAuth();
  const navigate = useNavigate();
  const [listing, setListing] = useState(null);
  const [loading, setLoading] = useState(true);
  const [photo, setPhoto] = useState(0);
  const [saved, setSaved] = useState(false);
  const [savingWatch, setSavingWatch] = useState(false);
  const [editing, setEditing] = useState(false);
  const [showBoost, setShowBoost] = useState(false);
  const [boosting, setBoosting] = useState(false);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [chatting, setChatting] = useState(false);
  const [sellerRating, setSellerRating] = useState(null);

  // Milestone 11: the seller's rating summary for the seller card.
  useEffect(() => {
    if (!listing?.seller_id) return;
    let cancelled = false;
    fetchSellerRating(listing.seller_id).then((r) => {
      if (!cancelled) setSellerRating(r);
    });
    return () => {
      cancelled = true;
    };
  }, [listing?.seller_id]);

  async function chatSeller() {
    if (!user || !listing) return;
    setError("");
    setChatting(true);
    try {
      const { conversation, error: chatError } = await startConversation(listing);
      if (chatError || !conversation) {
        setError(chatError || "Could not start the chat. Please try again.");
        return;
      }
      navigate(`/chat/${conversation.id}`);
    } finally {
      setChatting(false);
    }
  }

  const isOwner = user && listing && listing.seller_id === user.id;

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fetchListing(id).then((row) => {
      if (cancelled) return;
      setListing(row);
      setLoading(false);
      if (row && (!user || row.seller_id !== user.id)) bumpViews(row);
    });
    if (user) {
      fetchWatchlistIds(user.id).then((ids) => {
        if (!cancelled) setSaved(ids.includes(id));
      });
    }
    return () => {
      cancelled = true;
    };
  }, [id, user]);

  async function toggleWatch() {
    if (!user) return;
    setSavingWatch(true);
    const ok = await setWatchlisted(user.id, id, !saved);
    if (ok) setSaved(!saved);
    setSavingWatch(false);
  }

  async function doBoost(amount) {
    setBoosting(true);
    setError("");
    try {
      const updated = await boostListing(id, amount);
      setListing(updated);
      setShowBoost(false);
      setNotice(
        `Boosted — your listing ranks first until ${new Date(updated.boosted_until).toLocaleString("en-NG", { day: "numeric", month: "short", hour: "numeric", minute: "2-digit" })}.`
      );
    } catch (err) {
      setError(err?.message || "Could not boost this listing. Try again.");
    } finally {
      setBoosting(false);
    }
  }

  async function setStatus(status) {
    setError("");
    try {
      const updated = await updateListing(id, { status });
      setListing(updated);
      setNotice(
        status === "active"
          ? "Your listing is live again."
          : status === "reserved"
            ? "Marked as reserved — other students see it is on hold."
            : "Marked as sold. Congratulations on the sale."
      );
    } catch (err) {
      setError(err?.message || "Could not update the listing. Try again.");
    }
  }

  async function doDelete() {
    if (!confirmDelete) {
      setConfirmDelete(true);
      return;
    }
    try {
      await deleteListing(id);
      navigate("/dashboard");
    } catch (err) {
      setError(err?.message || "Could not delete the listing. Try again.");
    }
  }

  async function doDuplicate() {
    try {
      const copy = await duplicateListing(listing);
      navigate(`/listing/${copy.id}`);
    } catch (err) {
      setError(err?.message || "Could not duplicate the listing. Try again.");
    }
  }

  if (loading) {
    return <p className="pt-6 text-sm text-neutral-500">Loading listing…</p>;
  }

  if (!listing) {
    return (
      <EmptyState
        title="This listing is no longer available"
        body="It may have been sold or removed by the seller."
        action={
          <Link to="/search">
            <PrimaryButton>Browse listings</PrimaryButton>
          </Link>
        }
      />
    );
  }

  const cash = feeBreakdown(listing.price, "cash");
  const held = feeBreakdown(listing.price, "held");
  const boosted = isBoosted(listing);
  const meets = (listing.delivery_methods || []).includes("meetup");
  const ships = (listing.delivery_methods || []).includes("shipping");

  return (
    <div className="space-y-5">
      {listing.photos?.length ? (
        <div>
          <img
            src={listing.photos[photo]}
            alt={listing.title}
            className="h-72 w-full rounded-2xl object-cover"
          />
          {listing.photos.length > 1 ? (
            <div className="mt-2 flex gap-2">
              {listing.photos.map((p, i) => (
                <button key={i} onClick={() => setPhoto(i)} aria-label={`Photo ${i + 1}`}>
                  <img
                    src={p}
                    alt=""
                    className={`h-16 w-16 rounded-xl object-cover ${i === photo ? "ring-2 ring-brown" : "opacity-70"}`}
                  />
                </button>
              ))}
            </div>
          ) : null}
        </div>
      ) : (
        <div className="flex h-56 items-center justify-center rounded-2xl bg-neutral-100 text-sm text-neutral-400 dark:bg-neutral-900">
          No photo yet
        </div>
      )}

      <div>
        <div className="flex items-start justify-between gap-2">
          <h1 className="text-2xl font-bold">{listing.title}</h1>
          {boosted ? <BoostedBadge /> : null}
        </div>
        <p className="mt-1 text-2xl font-bold">{formatNaira(listing.price)}</p>
        <p className="mt-1 text-sm text-neutral-500">
          {listing.condition} · {listing.category} · {listing.views || 0} views
        </p>
        {listing.status !== "active" ? (
          <p className="mt-2 inline-block rounded-full bg-neutral-100 px-3 py-1 text-xs font-bold text-neutral-600 dark:bg-neutral-900 dark:text-neutral-300">
            {listing.status === "sold" ? "Sold" : "Reserved"}
          </p>
        ) : null}
      </div>

      {listing.description ? (
        <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
          <p className="font-bold">About this item</p>
          <p className="mt-1 whitespace-pre-wrap text-neutral-600 dark:text-neutral-300">
            {listing.description}
          </p>
        </div>
      ) : null}

      {/* Seller card */}
      <div className="flex items-center gap-3 rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
        <div className="flex h-12 w-12 items-center justify-center rounded-full bg-brown text-base font-bold text-white">
          {(listing.seller_label || "S")[0].toUpperCase()}
        </div>
        <div className="flex-1">
          <p className="font-bold">{listing.seller_label}</p>
          <p className="text-sm text-neutral-500">
            {listing.university} · {listing.state}
          </p>
          {sellerRating && sellerRating.count > 0 ? (
            <p className="text-sm font-semibold text-brown">
              ★ {sellerRating.average} · {sellerRating.count} rating{sellerRating.count === 1 ? "" : "s"}
            </p>
          ) : (
            <p className="text-sm text-neutral-400">No ratings yet</p>
          )}
        </div>
        <span className="rounded-full bg-brown-soft px-2.5 py-1 text-xs font-bold text-brown-dark">
          Verified student
        </span>
      </div>

      {/* Delivery */}
      <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
        <p className="font-bold">Delivery</p>
        {meets ? (
          <p className="mt-1">
            Meet in person{listing.meetup_spot ? ` — ${listing.meetup_spot}` : ""} ({listing.university})
          </p>
        ) : null}
        {ships ? (
          <p className="mt-1">
            Ships by {listing.courier || "courier"} —{" "}
            {listing.ships_to === "nationwide"
              ? "anywhere in Nigeria"
              : `within ${listing.state} only`}
          </p>
        ) : null}
        <p className="mt-2 text-neutral-500">
          Shipping estimate:{" "}
          {SHIPPING_ZONES.map((z) => `${z.label} ₦${typeof z.fee === "number" ? z.fee.toLocaleString("en-NG") : z.fee}`).join(" · ")}.
          Exact shipping is confirmed at checkout.
        </p>
      </div>

      {/* What the buyer pays — calculated automatically from the price */}
      <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
        <p className="font-bold">What the buyer pays</p>
        <p className="mt-2 flex justify-between">
          <span>Cash face-to-face (no fees)</span>
          <span className="font-bold">{formatNaira(cash.total)}</span>
        </p>
        <p className="mt-1 flex justify-between text-neutral-500">
          <span>Item price</span>
          <span>{formatNaira(held.price)}</span>
        </p>
        <p className="flex justify-between text-neutral-500">
          <span>Service fee (5%)</span>
          <span>{formatNaira(held.serviceFee)}</span>
        </p>
        <p className="flex justify-between text-neutral-500">
          <span>Secure payment fee</span>
          <span>{formatNaira(held.secureFee)}</span>
        </p>
        <p className="mt-1 flex justify-between font-bold">
          <span>Pay through the app (held)</span>
          <span>{formatNaira(held.total)}</span>
        </p>
        <p className="mt-1 text-neutral-500">
          The seller keeps the full {formatNaira(listing.price)}. Held money
          releases only after the buyer confirms the item.
        </p>
      </div>

      {/* Buyer actions */}
      {!isOwner && listing.status === "active" ? (
        <div className="space-y-2">
          {error ? (
            <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
              {error}
            </p>
          ) : null}
          <button
            onClick={toggleWatch}
            disabled={savingWatch}
            className="w-full rounded-full border border-neutral-300 px-4 py-2.5 text-sm font-semibold dark:border-neutral-700"
          >
            {saved ? "★ Saved to watchlist" : "☆ Save to watchlist"}
          </button>
          <PrimaryButton
            onClick={() => navigate(`/checkout/${listing.id}`)}
            className="w-full py-3 text-base"
          >
            Buy — Reserve this item
          </PrimaryButton>
          <GhostButton onClick={chatSeller} disabled={chatting} className="w-full py-2.5">
            {chatting ? "Opening chat…" : "Chat Seller"}
          </GhostButton>
          <p className="text-center text-xs text-neutral-500">
            Chat to ask questions or make an offer. Buying puts the money on
            hold until you confirm the item.
          </p>
        </div>
      ) : null}

      {/* Owner actions */}
      {isOwner ? (
        <div className="space-y-3">
          {notice ? (
            <p className="rounded-xl bg-brown-soft px-3 py-2 text-sm text-brown-dark">{notice}</p>
          ) : null}
          {error ? (
            <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">{error}</p>
          ) : null}
          {editing ? (
            <ListingEditForm
              listing={listing}
              onCancel={() => setEditing(false)}
              onSave={async (patch) => {
                const updated = await updateListing(id, patch);
                setListing(updated);
                setEditing(false);
                setNotice("Your listing was updated.");
              }}
            />
          ) : (
            <div className="flex flex-wrap gap-2">
              <GhostButton onClick={() => setEditing(true)}>Edit</GhostButton>
              <GhostButton onClick={doDuplicate}>Duplicate</GhostButton>
              {listing.status === "active" ? (
                <>
                  <GhostButton onClick={() => setStatus("reserved")}>Mark reserved</GhostButton>
                  <GhostButton onClick={() => setStatus("sold")}>Mark sold</GhostButton>
                </>
              ) : (
                <GhostButton onClick={() => setStatus("active")}>Back to active</GhostButton>
              )}
              <GhostButton onClick={doDelete}>
                {confirmDelete ? "Tap again to confirm delete" : "Delete"}
              </GhostButton>
            </div>
          )}

          {/* Boost */}
          <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
            <p className="font-bold">Boost this listing</p>
            {boosted ? (
              <p className="mt-1 text-neutral-500">
                Boosted until{" "}
                {new Date(listing.boosted_until).toLocaleString("en-NG", {
                  day: "numeric",
                  month: "short",
                  hour: "numeric",
                  minute: "2-digit",
                })}
                . Boosted listings show first with a “Boosted” label.
              </p>
            ) : (
              <p className="mt-1 text-neutral-500">
                Boosted listings show first with a “Boosted” label.
              </p>
            )}
            {showBoost ? (
              <div className="mt-3 space-y-2">
                {BOOST_TIERS.map((t) => (
                  <button
                    key={t.amount}
                    onClick={() => doBoost(t.amount)}
                    disabled={boosting}
                    className="flex w-full items-center justify-between rounded-xl border border-brown bg-brown-soft px-4 py-3 font-semibold text-brown-dark disabled:opacity-50"
                  >
                    <span>{t.label}</span>
                    <span>{boosting ? "Boosting…" : "Boost"}</span>
                  </button>
                ))}
                <p className="text-xs text-neutral-500">
                  Boost payment is demo for now — no real money moves until
                  real payments go live. Your boost still applies.
                </p>
                <button onClick={() => setShowBoost(false)} className="text-sm text-neutral-500 underline">
                  Cancel
                </button>
              </div>
            ) : (
              <div className="mt-3">
                <PrimaryButton onClick={() => setShowBoost(true)}>
                  {boosted ? "Extend boost" : "Boost this listing"}
                </PrimaryButton>
              </div>
            )}
          </div>
        </div>
      ) : null}
    </div>
  );
}
