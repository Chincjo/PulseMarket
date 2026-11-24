import { Link, useNavigate } from "react-router-dom";
import { CATEGORIES, UNIVERSITIES } from "../lib/data";
import { EmptyState, PrimaryButton } from "../components/ui";

export default function Home({ user }) {
  const navigate = useNavigate();
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
            const q = new FormData(e.target).get("q") || "";
            navigate(`/search?q=${encodeURIComponent(q)}`);
          }}
        >
          <input
            name="q"
            placeholder="Search items, e.g. calculator"
            className="w-full rounded-full border border-neutral-300 bg-white px-4 py-2.5 text-sm outline-none focus:border-brown dark:border-neutral-700 dark:bg-black"
          />
          <button className="rounded-full bg-brown px-5 py-2.5 text-sm font-semibold text-white">
            Search
          </button>
        </form>
        {!user ? (
          <div className="mt-4 flex flex-wrap gap-2">
            <Link to="/verify">
              <PrimaryButton>Join — get verified</PrimaryButton>
            </Link>
            <Link to="/verify">
              <span className="inline-flex items-center rounded-full border border-neutral-300 px-4 py-2.5 text-sm font-semibold dark:border-neutral-700">
                Sign in
              </span>
            </Link>
          </div>
        ) : null}
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
        <h2 className="text-lg font-bold">Near you</h2>
        <div className="mt-3">
          <EmptyState
            title="Nothing listed near you yet"
            body="Be the first seller on your campus — post your first item and students nearby will see it here."
            action={
              <Link to="/sell">
                <PrimaryButton>Post your first item</PrimaryButton>
              </Link>
            }
          />
        </div>
      </section>

      <section>
        <h2 className="text-lg font-bold">Just dropped</h2>
        <div className="mt-3">
          <EmptyState
            title="Fresh listings land here"
            body="No listings yet. Get verified so you can buy and sell the moment items appear."
            action={
              <Link to="/verify">
                <PrimaryButton>Get verified</PrimaryButton>
              </Link>
            }
          />
        </div>
      </section>

      <section>
        <h2 className="text-lg font-bold">Universities on PulseMarket</h2>
        <div className="mt-3 flex flex-wrap gap-2">
          {UNIVERSITIES.slice(0, 12).map((u) => (
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
