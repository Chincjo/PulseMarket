// Milestone 11 — Rating form for a completed order.
// Standalone: takes `order` and `onSubmitted` props and nothing else.
// The coordinator wires it into OrderDetail.jsx; this file is never
// imported there by itself. Buyer only, only once the order status is
// 'released', one rating per order (enforced again in ratings.js and
// in the database). After submitting it shows the rating that was
// given. Support: pulsemarketsupport@gmail.com.
import { useEffect, useState } from "react";
import { useAuth } from "../lib/auth";
import { fetchMyRatingForOrder, submitRating } from "../lib/ratings";
import { PrimaryButton } from "./ui";

function Stars({ value, onPick, disabled }) {
  return (
    <div className="flex items-center gap-1" role="radiogroup" aria-label="Stars">
      {[1, 2, 3, 4, 5].map((n) => (
        <button
          key={n}
          type="button"
          role="radio"
          aria-checked={value === n}
          aria-label={`${n} star${n === 1 ? "" : "s"}`}
          disabled={disabled}
          onClick={() => onPick(n)}
          className={`text-3xl leading-none ${
            n <= value ? "text-brown" : "text-neutral-300 dark:text-neutral-700"
          } disabled:opacity-60`}
        >
          ★
        </button>
      ))}
    </div>
  );
}

export default function RatingForm({ order, onSubmitted }) {
  const { user } = useAuth();
  const [existing, setExisting] = useState(null);
  const [loading, setLoading] = useState(true);
  const [stars, setStars] = useState(0);
  const [comment, setComment] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let alive = true;
    async function load() {
      if (!order?.id) {
        if (alive) setLoading(false);
        return;
      }
      const mine = await fetchMyRatingForOrder(order.id);
      if (alive) {
        setExisting(mine);
        setLoading(false);
      }
    }
    load();
    return () => {
      alive = false;
    };
  }, [order?.id]);

  if (!order) return null;

  if (loading) {
    return <p className="text-sm text-neutral-500">Loading rating…</p>;
  }

  const isBuyer = user && user.id === order.buyer_id;

  if (existing) {
    return (
      <div className="rounded-2xl border border-neutral-200 bg-neutral-50 p-4 dark:border-neutral-800 dark:bg-neutral-950">
        <p className="text-sm font-bold">You rated this order</p>
        <p className="mt-1 text-2xl leading-none" aria-label={`${existing.stars} out of 5 stars`}>
          <span className="text-brown">{"★".repeat(existing.stars)}</span>
          <span className="text-neutral-300 dark:text-neutral-700">
            {"★".repeat(5 - existing.stars)}
          </span>
        </p>
        {existing.comment && (
          <p className="mt-2 text-sm text-neutral-600 dark:text-neutral-300">
            “{existing.comment}”
          </p>
        )}
      </div>
    );
  }

  if (!isBuyer) {
    return (
      <p className="text-sm text-neutral-500">
        Only the buyer can rate this order.
      </p>
    );
  }

  if (order.status !== "released") {
    return (
      <p className="text-sm text-neutral-500">
        You can rate the seller once this order is released.
      </p>
    );
  }

  async function onSubmit() {
    setError("");
    if (stars < 1 || stars > 5) {
      setError("Tap 1 to 5 stars first.");
      return;
    }
    setBusy(true);
    try {
      const rating = await submitRating(order.id, { stars, comment });
      setExisting(rating);
      if (onSubmitted) onSubmitted(rating);
    } catch (err) {
      setError(err?.message || "Could not save your rating. Try again.");
    }
    setBusy(false);
  }

  return (
    <div className="rounded-2xl border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-black">
      <p className="text-sm font-bold">Rate the seller</p>
      <p className="mt-1 text-sm text-neutral-500">
        How did this deal go? Your rating helps other students trust this
        seller.
      </p>

      <div className="mt-3">
        <Stars value={stars} onPick={setStars} disabled={busy} />
      </div>

      <textarea
        value={comment}
        onChange={(e) => setComment(e.target.value)}
        rows={2}
        maxLength={280}
        disabled={busy}
        placeholder="Short comment (optional) — e.g. item as described, met on time"
        className="mt-3 w-full rounded-xl border border-neutral-300 bg-white px-3 py-2.5 text-sm outline-none focus:border-brown dark:border-neutral-700 dark:bg-black"
      />
      <p className="mt-1 text-right text-xs text-neutral-400">
        {comment.length}/280
      </p>

      {error && (
        <p className="mt-2 rounded-xl bg-red-50 px-3 py-2 text-sm text-red-700">
          {error}
        </p>
      )}

      <div className="mt-3">
        <PrimaryButton disabled={busy || stars < 1} onClick={onSubmit}>
          {busy ? "Saving…" : "Submit rating"}
        </PrimaryButton>
      </div>
    </div>
  );
}
