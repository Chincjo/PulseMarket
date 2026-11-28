import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { CATEGORIES, UNIVERSITY_NAMES, universityState } from "../lib/data";
import { EmptyState, PrimaryButton } from "../components/ui";
import { ListingCard } from "../components/ListingCard";
import { fetchActiveListings, sortListings, visibleTo } from "../lib/listings";

export default function Home({ verification }) {
  const navigate = useNavigate();
  const [listings, setListings] = useState([]);
  const [loadingListings, setLoadingListings] = useState(true);

  const myState = verification?.university
    ? universityState(verification.university)
    : "";

  useEffect(() => {
    let cancelled = false;
    // Home only ever shows 6 + 6 cards, so fetch 60 rows, not 200 —
    // the full 200-row payload (with photo URL arrays) is what made
    // "Near you" sit on "Loading listings…" on slow connections.
    fetchActiveListings(60)
      .then((rows) => {
        if (!cancelled) {
          setListings(rows);
          setLoadingListings(false);
        }
      })
      .catch(() => {
        // A rejected fetch (offline, cold Supabase) must never leave
        // the page stuck on "Loading listings…" for ever.
        if (!cancelled) {
          setListings([]);
          setLoadingListings(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // A listing is visible to this student when it is in their state, or the
  // seller ships anywhere in Nigeria. Same-state-only listings from other
  // states never appear here.
  const visible = listings.filter((l) => visibleTo(l, myState));
  const nearYou = sortListings(visible.filter((l) => l.state === myState));
  // Milestone 20 (APP-16): "Just dropped" must not repeat the
  // near-you items above it — the same listing used to show twice
  // on one screen.
  const nearYouIds = new Set(nearYou.map((l) => l.id));
  const justDropped = sortListings(visible.filter((l) => !nearYouIds.has(l.id)));

  return (
    <div className="space-y-8">
      <section className="pt-2">
        <h1 className="text-3xl font-bold leading-tight sm:text-4xl">
          Buy and sell safely with verified students.
        </h1>
        <p className="mt-2 text-neutral-500">
          Across every Nigerian campus. Your money stays on hold until you
          meet, inspect and approve.
        </p>
        <form
          className="mt-4 flex gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            const q = (new FormData(e.target).get("q") || "").toString().trim().slice(0, 200);
            navigate(`/search?q=${encodeURIComponent(q)}`);
          }}
        >
          <input
            name="q"
            maxLength={200}
            placeholder="Search items, e.g. calculator"
            className="w-full rounded-full border border-neutral-300 bg-white px-4 py-2.5 text-sm outline-none focus:border-brown dark:border-neutral-700 dark:bg-black"
          />
          <button className="rounded-full bg-brown px-5 py-2.5 text-sm font-semibold text-white">
            Search
          </button>
        </form>
      </section>

      <section>
        <h2 className="text-lg font-bold">How PulseMarket keeps you safe</h2>
        <div className="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-3">
          <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
            <p className="text-sm font-bold">1. Money on hold</p>
            <p className="mt-1 text-sm text-neutral-500">
              The buyer pays into hold. The seller never touches it until the
              buyer confirms.
            </p>
          </div>
          <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
            <p className="text-sm font-bold">2. Meet + inspect</p>
            <p className="mt-1 text-sm text-neutral-500">
              Meet at a safe spot, scan the seller code, check the item with
              photo and video.
            </p>
          </div>
          <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
            <p className="text-sm font-bold">3. Released</p>
            <p className="mt-1 text-sm text-neutral-500">
              Money releases to the seller after approval — or automatically
              after 48 hours.
            </p>
          </div>
        </div>
      </section>

      <section>
        <h2 className="text-lg font-bold">Trending</h2>
        <div className="mt-3 flex flex-wrap gap-2">
          {CATEGORIES.map((c) => (
            <Link
              key={c}
              to={`/search?category=${encodeURIComponent(c)}`}
              className="rounded-full border border-neutral-300 px-3 py-1.5 text-sm dark:border-neutral-700"
            >
              {c}
            </Link>
          ))}
        </div>
      </section>

      <section>
        <h2 className="text-lg font-bold">Near you{myState ? ` — ${myState}` : ""}</h2>
        <div className="mt-3">
          {loadingListings ? (
            <p className="text-sm text-neutral-500">Loading listings…</p>
          ) : nearYou.length === 0 ? (
            // No state is known yet (verification has no university)
            // — "nothing near you" would be a lie, because the page
            // has no idea where "near you" is.
            myState ? (
              <EmptyState
                title="Nothing listed near you yet"
                body="Be the first seller on your campus — post your first item and students nearby will see it here."
                action={
                  <Link to="/sell">
                    <PrimaryButton>Post your first item</PrimaryButton>
                  </Link>
                }
              />
            ) : (
              <p className="text-sm text-neutral-500">
                Listings near you will appear here once your university is set.
              </p>
            )
          ) : (
            <div className="grid grid-cols-2 gap-3">
              {nearYou.slice(0, 6).map((l) => (
                <ListingCard key={l.id} listing={l} />
              ))}
            </div>
          )}
        </div>
      </section>

      <section>
        <h2 className="text-lg font-bold">Just dropped</h2>
        <div className="mt-3">
          {loadingListings ? (
            <p className="text-sm text-neutral-500">Loading listings…</p>
          ) : justDropped.length === 0 ? (
            // The "Get verified" line used to show to everyone,
            // including students already approved — only offer it
            // to someone who is not approved yet.
            <EmptyState
              title="Fresh listings land here"
              body={
                verification?.status === "approved"
                  ? "No listings yet. Post the item yourself and students across Nigeria will see it here."
                  : "No listings yet. Get verified so you can buy and sell the moment items appear."
              }
              action={
                verification?.status === "approved" ? (
                  <Link to="/sell">
                    <PrimaryButton>Sell an item</PrimaryButton>
                  </Link>
                ) : (
                  <Link to="/verify">
                    <PrimaryButton>Get verified</PrimaryButton>
                  </Link>
                )
              }
            />
          ) : (
            <div className="grid grid-cols-2 gap-3">
              {justDropped.slice(0, 6).map((l) => (
                <ListingCard key={l.id} listing={l} />
              ))}
            </div>
          )}
        </div>
      </section>

      <section>
        <h2 className="text-lg font-bold">Universities on PulseMarket</h2>
        <div className="mt-3 flex flex-wrap gap-2">
          {UNIVERSITY_NAMES.slice(0, 12).map((u) => (
            <span
              key={u}
              className="rounded-full bg-neutral-100 px-3 py-1.5 text-sm dark:bg-neutral-900"
            >
              {u}
            </span>
          ))}
          <span className="rounded-full bg-brown-soft px-3 py-1.5 text-sm font-semibold text-brown-dark">
            + more across Nigeria
          </span>
        </div>
      </section>
    </div>
  );
}
