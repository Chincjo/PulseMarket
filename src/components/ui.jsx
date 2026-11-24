export function Logo({ size = 36 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 64 64" aria-label="PulseMarket logo">
      <rect width="64" height="64" rx="14" fill="#111111" />
      <path
        d="M10 34h10l5-12 8 22 6-14 3 4h12"
        fill="none"
        stroke="#ffffff"
        strokeWidth="4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <circle cx="52" cy="18" r="4" fill="#7d5027" />
    </svg>
  );
}

export function EmptyState({ title, body, action }) {
  return (
    <div className="rounded-2xl border border-neutral-200 bg-neutral-50 px-5 py-8 text-center dark:border-neutral-800 dark:bg-neutral-950">
      <p className="text-base font-semibold">{title}</p>
      <p className="mt-1 text-sm text-neutral-500">{body}</p>
      {action ? <div className="mt-4">{action}</div> : null}
    </div>
  );
}

export function PrimaryButton({ children, ...props }) {
  return (
    <button
      className="inline-flex items-center justify-center rounded-full bg-brown px-5 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
      {...props}
    >
      {children}
    </button>
  );
}

export function GhostButton({ children, ...props }) {
  return (
    <button
      className="inline-flex items-center justify-center rounded-full border border-neutral-300 px-4 py-2 text-sm font-semibold dark:border-neutral-700"
      {...props}
    >
      {children}
    </button>
  );
}

export const inputCls =
  "w-full rounded-xl border border-neutral-300 bg-white px-3 py-2.5 text-sm outline-none focus:border-brown dark:border-neutral-700 dark:bg-black";
