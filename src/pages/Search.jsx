// Search real listings (Milestone 4) — query, category, condition,
// university, state, price range and sort. Boosted listings rank first.
// Only listings the student can actually buy appear: same-state listings
// from their own state, plus nationwide-shipping listings from anywhere.
import { useEffect, useMemo, useState } from "react";
import { useSearchParams, Link } from "react-router-dom";
import { CATEGORIES, CONDITIONS, STATES, UNIVERSITY_NAMES, universityState } from "../lib/data";
import { getVerification } from "../lib/store";
import { EmptyState, PrimaryButton, inputCls } from "../components/ui";
import { ListingCard } from "../components/ListingCard";
import { fetchActiveListings, sortListings, visibleTo } from "../lib/listings";

export default function Search() {
  const [params] = useSearchParams();
  const [q, setQ] = useState(params.get("q") || "");
  const [category, setCategory] = useState(params.get("category") || "");
  const [condition, setCondition] = useState("");
  const [university, setUniversity] = useState("");
  const [state, setState] = useState("");
  const [min, setMin] = useState("");
  const [max, setMax] = useState("");
  const [sort, setSort] = useState("newest");
  const [all, setAll] = useState([]);
  const [loading, setLoading] = useState(true);

  const myState = universityState(getVerification()?.university || "");

  useEffect(() => {
    let cancelled = false;
    // Milestone 20 (APP-16): capped at 200 rows — the page never
    // needs more than a screenful of candidates to filter and sort.
    fetchActiveListings(200)
      .then((rows) => {
        if (!cancelled) {
          setAll(rows);
          setLoading(false);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setAll([]);
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  // Keep the URL in sync when a category pill is tapped from Home.
  useEffect(() => {
    const c = params.get("category") || "";
    setCategory(c);
    const query = params.get("q") || "";
    setQ(query);
  }, [params]);

  // Price bounds are sanitised: empty, negative or non-numeric input
  // is ignored instead of silently filtering everything out.
  const minNum = min === "" ? null : Math.max(0, Math.floor(Number(min) || 0));
  const maxNum = max === "" ? null : Math.max(0, Math.floor(Number(max) || 0));
  const priceRangeBad = minNum !== null && maxNum !== null && minNum > maxNum;

  const results = useMemo(() => {
    let list = all.filter((d) => visibleTo(d, myState));
    if (q) list = list.filter((d) => `${d.title} ${d.description || ""}`.toLowerCase().includes(q.toLowerCase()));
    if (category) list = list.filter((d) => d.category === category);
    if (condition) list = list.filter((d) => d.condition === condition);
    if (university) list = list.filter((d) => d.university === university);
    if (state) list = list.filter((d) => d.state === state);
    if (minNum !== null) list = list.filter((d) => d.price >= minNum);
    if (maxNum !== null) list = list.filter((d) => d.price <= maxNum);
    if (sort === "price-low") return [...list].sort((a, b) => a.price - b.price);
    if (sort === "price-high") return [...list].sort((a, b) => b.price - a.price);
    return sortListings(list);
  }, [all, q, category, condition, university, state, minNum, maxNum, sort, myState]);

  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-bold">Search</h1>
      <input
        value={q}
        onChange={(e) => setQ(e.target.value.slice(0, 200))}
        placeholder="Search items"
        maxLength={200}
        className="w-full rounded-full border border-neutral-300 bg-white px-4 py-2.5 text-sm outline-none focus:border-brown dark:border-neutral-700 dark:bg-black"
      />
      <div className="flex flex-wrap gap-2">
        <button
          onClick={() => setCategory("")}
          className={`rounded-full px-3 py-1.5 text-sm ${!category ? "bg-brown text-white" : "border border-neutral-300 dark:border-neutral-700"}`}
        >
          All
        </button>
        {CATEGORIES.map((c) => (
          <button
            key={c}
            onClick={() => setCategory(c === category ? "" : c)}
            className={`rounded-full px-3 py-1.5 text-sm ${c === category ? "bg-brown text-white" : "border border-neutral-300 dark:border-neutral-700"}`}
          >
            {c}
          </button>
        ))}
      </div>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
        <select value={condition} onChange={(e) => setCondition(e.target.value)} className={inputCls}>
          <option value="">Any condition</option>
          {CONDITIONS.map((c) => (
            <option key={c}>{c}</option>
          ))}
        </select>
        <select value={university} onChange={(e) => setUniversity(e.target.value)} className={inputCls}>
          <option value="">Any university</option>
          {UNIVERSITY_NAMES.map((u) => (
            <option key={u}>{u}</option>
          ))}
        </select>
        <select value={state} onChange={(e) => setState(e.target.value)} className={inputCls}>
          <option value="">Any state</option>
          {STATES.map((s) => (
            <option key={s}>{s}</option>
          ))}
        </select>
        <input value={min} onChange={(e) => setMin(e.target.value)} placeholder="Min ₦" type="number" className={inputCls} />
        <input value={max} onChange={(e) => setMax(e.target.value)} placeholder="Max ₦" type="number" className={inputCls} />
        <select value={sort} onChange={(e) => setSort(e.target.value)} className={inputCls}>
          <option value="newest">Newest first</option>
          <option value="price-low">Price: low to high</option>
          <option value="price-high">Price: high to low</option>
        </select>
      </div>
      <div className="flex items-center justify-between">
        <p className="text-sm text-neutral-500">
          {loading
            ? "Loading listings…"
            : `${results.length} result${results.length === 1 ? "" : "s"}`}
        </p>
        {priceRangeBad ? (
          <p className="text-sm font-semibold text-red-700">
            Min price is above max price — no item can match both.
          </p>
        ) : null}
      </div>
      {/* A state filter on another state hides that state's
          same-state-only listings (they cannot reach a buyer in a
          different state) — say so, or the search looks broken. */}
      {state && myState && state !== myState ? (
        <p className="text-sm text-neutral-500">
          Listings that only sell in {state} are hidden — you are in {myState}, so only listings from {state} that ship nationwide can reach you.
        </p>
      ) : null}
      {!loading && results.length === 0 ? (
        <EmptyState
          title="No listings match yet"
          body="Listings from verified students across Nigeria will appear here. Try a different search or post the item yourself."
          action={
            <Link to="/sell">
              <PrimaryButton>Sell an item</PrimaryButton>
            </Link>
          }
        />
      ) : (
        <div className="grid grid-cols-2 gap-3">
          {results.map((d) => (
            <ListingCard key={d.id} listing={d} />
          ))}
        </div>
      )}
    </div>
  );
}
