import { Link } from "react-router-dom";
import { getVerification } from "../lib/store";
import { GhostButton, PrimaryButton } from "../components/ui";
import { logout } from "../lib/identity";

export default function Profile({ user }) {
  const verification = getVerification();
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <div className="flex h-14 w-14 items-center justify-center rounded-full bg-brown text-lg font-bold text-white">
          {(user?.email?.[0] || "P").toUpperCase()}
        </div>
        <div className="flex-1">
          <p className="font-bold">{user?.email || "Guest"}</p>
          <p className="text-sm text-neutral-500">
            {verification?.university || "Not verified yet"}
            {verification ? ` · ${verification.status}` : ""}
          </p>
        </div>
        {verification ? (
          <span className="rounded-full bg-brown-soft px-2.5 py-1 text-xs font-bold text-brown-dark">
            Verified student
          </span>
        ) : null}
      </div>

      <div className="flex gap-2">
        <Link to="/settings" className="flex-1">
          <GhostButton className="w-full">Settings</GhostButton>
        </Link>
        <Link to="/settings" className="flex-1">
          <GhostButton className="w-full">Saved items</GhostButton>
        </Link>
        <Link to="/settings" className="flex-1">
          <GhostButton className="w-full">Notifications</GhostButton>
        </Link>
      </div>

      {!user ? (
        <div className="rounded-2xl border border-neutral-200 p-4 text-center dark:border-neutral-800">
          <p className="font-bold">Join PulseMarket</p>
          <p className="mt-1 text-sm text-neutral-500">
            Create an account and verify your student status to buy and sell.
          </p>
          <Link to="/verify" className="mt-3 inline-block">
            <PrimaryButton>Join — get verified</PrimaryButton>
          </Link>
        </div>
      ) : (
        <div className="space-y-2">
          <div className="flex justify-between rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
            <span className="text-neutral-500">Email</span>
            <span className="font-semibold">{user.email}</span>
          </div>
          {verification ? (
            <>
              <div className="flex justify-between rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
                <span className="text-neutral-500">University (locked)</span>
                <span className="font-semibold">{verification.university}</span>
              </div>
              <div className="flex justify-between rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
                <span className="text-neutral-500">Invite code</span>
                <span className="font-semibold">{verification.inviteCode || "—"}</span>
              </div>
            </>
          ) : null}
          <button
            onClick={() => logout()}
            className="w-full rounded-full border border-neutral-300 px-4 py-2.5 text-sm font-semibold dark:border-neutral-700"
          >
            Sign out
          </button>
        </div>
      )}
    </div>
  );
}
