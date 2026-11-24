import { useMemo, useState } from "react";
import { useSearchParams, Link } from "react-router-dom";
import { CATEGORIES, CONDITIONS, UNIVERSITIES } from "../lib/data";
import { getDrafts } from "../lib/store";
import { formatNaira } from "../lib/fees";
import { EmptyState, PrimaryButton, inputCls } from "../components/ui";

export default function Search() {
  const [params, setParams] = useSearchParams();
  const [q, setQ] = useState(params.get("q") || "");
  const [category, setCategory] = useState(params.get("category") || "");
  const [condition, setCondition] = useState("");
  const [university, setUniversity] = useState("");
  const [min, setMin] = useState("");
  const [max, setMax] = useState("");
  const [sort, setSort] = useState("newest");

  const results = useMemo(() => {
    let list = getDrafts();
    if (q) list = list.filter((d) => (d.name || "").toLowerCase().includes(q.toLowerCase()));
    if (category) list = list.filter((d) => d.category === category);
    if (condition) list = list.filter((d) => d.condition === condition);
    if (university) list = list.filter((d) => d.university === university);
    if (min) list = list.filter((d) => d.price >= Number(min));
    if (max) list = list.filter((d) => d.price <= Number(max));
    if (sort === "price-low") list = [...list].sort((a, b) => a.price - b.price);
    if (sort === "price-high") list = [...list].sort((a, b) => b.price - a.price);
    return list;
  }, [q, category, condition, university, min, max, sort]);

  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-bold">Search</h1>
      <input
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Search items"
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
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <select value={condition} onChange={(e) => setCondition(e.target.value)} className={inputCls}>
          <option value="">Any condition</option>
          {CONDITIONS.map((c) => (
            <option key={c}>{c}</option>
          ))}
        </select>
        <select value={university} onChange={(e) => setUniversity(e.target.value)} className={inputCls}>
          <option value="">Any university</option>
          {UNIVERSITIES.map((u) => (
            <option key={u}>{u}</option>
          ))}
        </select>
        <input value={min} onChange={(e) => setMin(e.target.value)} placeholder="Min ₦" type="number" className={inputCls} />
        <input value={max} onChange={(e) => setMax(e.target.value)} placeholder="Max ₦" type="number" className={inputCls} />
      </div>
      <div className="flex items-center justify-between">
        <p className="text-sm text-neutral-500">
          {results.length} result{results.length === 1 ? "" : "s"}
        </p>
        <select value={sort} onChange={(e) => setSort(e.target.value)} className="rounded-full border border-neutral-300 px-3 py-1.5 text-sm dark:border-neutral-700 dark:bg-black">
          <option value="newest">Newest first</option>
          <option value="price-low">Price: low to high</option>
          <option value="price-high">Price: high to low</option>
        </select>
      </div>
      {results.length === 0 ? (
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
            <div key={d.id} className="rounded-2xl border border-neutral-200 p-3 dark:border-neutral-800">
              {d.photos?.[0] ? (
                <img src={d.photos[0]} alt={d.name} className="h-32 w-full rounded-xl object-cover" />
              ) : (
                <div className="flex h-32 items-center justify-center rounded-xl bg-neutral-100 text-sm text-neutral-400 dark:bg-neutral-900">
                  No photo yet
                </div>
              )}
              <p className="mt-2 text-sm font-semibold">{d.name}</p>
              <p className="text-sm text-neutral-500">
                {d.condition} · {d.university}
              </p>
              <p className="mt-1 font-bold">{formatNaira(d.price)}</p>
              <span className="mt-1 inline-block rounded-full bg-brown-soft px-2 py-0.5 text-xs font-semibold text-brown-dark">
                Draft — yours
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
