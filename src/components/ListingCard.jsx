import { Link } from "react-router-dom";
import { formatNaira } from "../lib/fees";
import { isBoosted } from "../lib/listings";

export function BoostedBadge() {
  return (
    <span className="inline-block rounded-full bg-brown px-2 py-0.5 text-xs font-bold text-white">
      Boosted
    </span>
  );
}

export function ListingCard({ listing }) {
  return (
    <Link
      to={`/listing/${listing.id}`}
      className="block rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800"
    >
      {listing.photos?.[0] ? (
        <img
          src={listing.photos[0]}
          alt={listing.title}
          className="h-32 w-full rounded-xl object-cover"
          loading="lazy"
        />
      ) : (
        <div className="flex h-32 items-center justify-center rounded-xl bg-neutral-100 text-sm text-neutral-400 dark:bg-neutral-900">
          No photo yet
        </div>
      )}
      <div className="mt-2 flex items-start justify-between gap-2">
        <p className="text-sm font-semibold">{listing.title}</p>
        {isBoosted(listing) ? <BoostedBadge /> : null}
      </div>
      <p className="text-sm text-neutral-500">
        {listing.condition} · {listing.university}
      </p>
      <p className="text-sm text-neutral-500">{listing.state}</p>
      <p className="mt-1 font-bold">{formatNaira(listing.price)}</p>
      {listing.ships_to === "nationwide" ? (
        <span className="mt-1 inline-block rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-semibold text-neutral-600 dark:bg-neutral-900 dark:text-neutral-300">
          Ships nationwide
        </span>
      ) : (
        <span className="mt-1 inline-block rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-semibold text-neutral-600 dark:bg-neutral-900 dark:text-neutral-300">
          Same state only
        </span>
      )}
    </Link>
  );
}
