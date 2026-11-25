// Milestone 11 — Invite page (route /invite, added by the
// coordinator). Shows the signed-in student's invite code big, a copy
// button, a share message, and how many students joined with their
// code. The count is honest: 0 means nobody has joined with the code
// yet; when the count cannot be read (owner has not run
// supabase/milestone-11.sql yet) the page says so instead of showing
// a fake 0. Support: pulsemarketsupport@gmail.com.
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { fetchReferralCount, getOrCreateInviteCode } from "../lib/ratings";
import { EmptyState, GhostButton, PrimaryButton } from "../components/ui";

export default function Invite() {
  const { user } = useAuth();
  const [code, setCode] = useState(null);
  const [count, setCount] = useState(null);
  const [loading, setLoading] = useState(true);
  const [noVerification, setNoVerification] = useState(false);
  const [copied, setCopied] = useState(false);
  const [shared, setShared] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    let alive = true;
    async function load() {
      if (!user) {
        setLoading(false);
        return;
      }
      try {
        const inviteCode = await getOrCreateInviteCode(user.id);
        if (!alive) return;
        if (!inviteCode) {
          setNoVerification(true);
          setLoading(false);
          return;
        }
        setCode(inviteCode);
        const joined = await fetchReferralCount(inviteCode);
        if (!alive) return;
        setCount(joined);
      } catch (err) {
        if (alive) setError(err?.message || "Could not load your invite code. Try again.");
      } finally {
        if (alive) setLoading(false);
      }
    }
    load();
    return () => {
      alive = false;
    };
  }, [user]);

  if (loading) {
    return <p className="py-10 text-center text-sm text-neutral-500">Loading your invite code…</p>;
  }

  if (error) {
    return (
      <EmptyState
        title="Could not load your invite code"
        body={error}
        action={
          <Link to="/dashboard">
            <GhostButton>Back to dashboard</GhostButton>
          </Link>
        }
      />
    );
  }

  if (!user) {
    return (
      <EmptyState
        title="Sign in to invite students"
        body="Your invite code lives on your verified student account. Sign in first, then come back here."
        action={
          <Link to="/signin">
            <PrimaryButton>Sign in</PrimaryButton>
          </Link>
        }
      />
    );
  }

  if (noVerification || !code) {
    return (
      <EmptyState
        title="Verify as a student first"
        body="Your invite code is created with your student verification. Finish verification and your code will show here."
        action={
          <Link to="/verify">
            <PrimaryButton>Verify as a student</PrimaryButton>
          </Link>
        }
      />
    );
  }

  const shareMessage = `Join PulseMarket with my invite code ${code} — verified students buy and sell safely`;

  async function copyCode() {
    setError("");
    setCopied(false);
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(code);
      } else {
        const area = document.createElement("textarea");
        area.value = code;
        document.body.appendChild(area);
        area.select();
        document.execCommand("copy");
        document.body.removeChild(area);
      }
      setCopied(true);
    } catch {
      setError("Could not copy — long-press the code to copy it by hand.");
    }
  }

  async function shareInvite() {
    setError("");
    setShared(false);
    if (navigator.share) {
      try {
        await navigator.share({ text: shareMessage });
        setShared(true);
      } catch {
        // The student closed the share sheet — not an error.
      }
      return;
    }
    await copyCode();
    setShared(false);
  }

  return (
    <div className="space-y-5">
      <div>
        <h1 className="text-2xl font-bold">Invite students</h1>
        <p className="mt-1 text-sm text-neutral-500">
          Share your invite code — every student who joins with it is
          counted here.
        </p>
      </div>

      <section className="rounded-2xl border border-neutral-200 bg-white p-5 text-center dark:border-neutral-800 dark:bg-black">
        <p className="text-sm text-neutral-500">Your invite code</p>
        <p className="mt-2 text-4xl font-bold tracking-widest text-brown">
          {code}
        </p>
        <div className="mt-4 flex flex-wrap justify-center gap-2">
          <PrimaryButton onClick={copyCode}>
            {copied ? "Copied ✓" : "Copy code"}
          </PrimaryButton>
          <GhostButton onClick={shareInvite}>
            {shared ? "Shared ✓" : "Share invite"}
          </GhostButton>
        </div>
        {error && (
          <p className="mx-auto mt-3 max-w-md rounded-xl bg-red-50 px-3 py-2 text-sm text-red-700">
            {error}
          </p>
        )}
      </section>

      <section className="rounded-2xl border border-neutral-200 bg-neutral-50 p-4 dark:border-neutral-800 dark:bg-neutral-950">
        <p className="text-sm font-bold">Share message</p>
        <p className="mt-1 text-sm text-neutral-600 dark:text-neutral-300">
          {shareMessage}
        </p>
      </section>

      <section className="rounded-2xl border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-black">
        <p className="text-sm font-bold">Students who joined with your code</p>
        {count === null ? (
          <p className="mt-1 text-sm text-neutral-500">
            Referral counting is not switched on yet — the PulseMarket team
            needs to run supabase/milestone-11.sql first.
          </p>
        ) : (
          <p className="mt-1 text-2xl font-bold">
            {count}{" "}
            <span className="text-base font-semibold text-neutral-500">
              {count === 1 ? "student" : "students"}
            </span>
          </p>
        )}
        {count === 0 && (
          <p className="mt-1 text-sm text-neutral-500">
            Nobody has joined with your code yet — share it with students
            at your university.
          </p>
        )}
      </section>
    </div>
  );
}
