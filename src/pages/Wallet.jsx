import { formatNaira } from "../lib/fees";
import { EmptyState } from "../components/ui";

export default function Wallet() {
  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-bold">Wallet</h1>
      <div className="grid grid-cols-2 gap-2 text-center">
        <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <p className="text-xl font-bold">{formatNaira(0)}</p>
          <p className="text-xs text-neutral-500">Available</p>
        </div>
        <div className="rounded-2xl border border-neutral-200 p-4 dark:border-neutral-800">
          <p className="text-xl font-bold">{formatNaira(0)}</p>
          <p className="text-xs text-neutral-500">In hold</p>
        </div>
      </div>
      <button
        disabled
        className="w-full rounded-full bg-neutral-200 px-5 py-3 text-sm font-semibold text-neutral-500 dark:bg-neutral-800"
      >
        Withdraw — opens with real payments (Milestone 6)
      </button>
      <h2 className="text-lg font-bold">Ledger</h2>
      <EmptyState
        title="No money movement yet"
        body="Held payments, releases and refunds will show here, computed from the ledger — never from a stored balance."
      />
      <p className="text-xs text-neutral-400">
        Demo note: all money in this build is shown honestly as ₦0 until held
        payments go live. Nothing here is real money yet.
      </p>
    </div>
  );
}
