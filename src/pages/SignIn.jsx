// Sign-in page — separate from the home page, no bottom navigation.
// Returning students sign in here; new students go to Join & verify.
import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { GhostButton, PrimaryButton, inputCls } from "../components/ui";

function friendlyError(err) {
  const msg = err?.message || "";
  if (/invalid login credentials/i.test(msg))
    return "That email or password does not match our records. Check them and try again.";
  if (/email not confirmed/i.test(msg))
    return "Please confirm your email first — check your inbox for the confirmation link.";
  if (/provider is not enabled/i.test(msg))
    return "Google sign-in is not switched on yet — please use your email and password for now.";
  if (/network|fetch failed/i.test(msg))
    return "Could not reach the server. Check your connection and try again.";
  return msg || "Something went wrong. Please try again.";
}

export default function SignIn() {
  const { configured, signInEmail, signInGoogle } = useAuth();
  const navigate = useNavigate();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setError("");
    if (!configured) {
      setError("Student accounts are being switched on — please check back shortly.");
      return;
    }
    // A whitespace-only email used to reach Supabase and come back as
    // a confusing "invalid credentials" error.
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) {
      setError("Enter a valid email address.");
      return;
    }
    if (!password) {
      setError("Enter your password.");
      return;
    }
    setBusy(true);
    try {
      await signInEmail(email.trim(), password);
      navigate("/");
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function google() {
    setError("");
    if (!configured) {
      setError("Student accounts are being switched on — please check back shortly.");
      return;
    }
    try {
      await signInGoogle();
    } catch (err) {
      setError(friendlyError(err));
    }
  }

  return (
    <div className="mx-auto max-w-sm space-y-5 pt-10">
      <h1 className="text-2xl font-bold">Sign in</h1>
      <p className="text-neutral-500">
        Welcome back. Sign in to continue to PulseMarket.
      </p>

      <form onSubmit={submit} className="space-y-3">
        <label className="block text-sm font-semibold">
          Email address
          <input
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            type="email"
            placeholder="you@example.com"
            className={`${inputCls} mt-1`}
          />
        </label>
        <label className="block text-sm font-semibold">
          Password
          <input
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            type="password"
            placeholder="Your password"
            className={`${inputCls} mt-1`}
          />
        </label>
        {error ? (
          <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
            {error}
          </p>
        ) : null}
        <PrimaryButton
          className="w-full"
          disabled={busy || !email.trim() || !password}
        >
          {busy ? "Signing in…" : "Sign in"}
        </PrimaryButton>
      </form>

      <GhostButton className="w-full" onClick={google}>
        Continue with Google
      </GhostButton>

      <p className="text-center text-sm text-neutral-500">
        New to PulseMarket?{" "}
        <Link to="/verify" className="font-semibold text-brown underline">
          Join & verify
        </Link>
      </p>
    </div>
  );
}
