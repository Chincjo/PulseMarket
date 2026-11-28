// Sign-in page — separate from the home page, no bottom navigation.
// Returning students sign in here; new students go to Join & verify.
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { useAuth } from "../lib/auth";
import { supabase } from "../lib/supabase";
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
  // Milestone 20 (APP-16): password reset — sends a reset link to
  // the email typed above, nothing more. The link returns to this
  // page, where the student sets a new password.
  const [resetSent, setResetSent] = useState(false);
  const [resetBusy, setResetBusy] = useState(false);
  // The return half of the reset: the student arrives back here
  // from the link in their inbox and sets the new password. The
  // old page had NO way to do this — the link landed on the plain
  // sign-in form and the reset dead-ended.
  const [recoveryMode, setRecoveryMode] = useState(false);
  const [newPassword, setNewPassword] = useState("");
  const [newConfirm, setNewConfirm] = useState("");

  useEffect(() => {
    // The recovery session can be detected before this page mounts,
    // so the event alone is not enough — check the link itself too.
    let subscription;
    if (supabase) {
      const { data } = supabase.auth.onAuthStateChange((event) => {
        if (event === "PASSWORD_RECOVERY") setRecoveryMode(true);
      });
      subscription = data?.subscription;
    }
    const hash = window.location.hash || "";
    const params = new URLSearchParams(window.location.search || "");
    // Implicit flow: #access_token=...&type=recovery. A bare ?code=
    // used to trigger recovery mode too, but any PKCE link can land
    // here with a code — a Google sign-in or an email confirmation
    // would then wrongly show "Set a new password" instead of the
    // sign-in form. Recovery is detected by the PASSWORD_RECOVERY
    // event above (fired once the client exchanges the code) or by
    // an explicit type=recovery on the link itself.
    if (hash.includes("type=recovery") || params.get("type") === "recovery") {
      setRecoveryMode(true);
    }
    return () => {
      subscription?.unsubscribe();
    };
  }, []);

  async function saveNewPassword(e) {
    e.preventDefault();
    setError("");
    if (newPassword.length < 6) {
      setError("Password must be at least 6 characters.");
      return;
    }
    if (newPassword !== newConfirm) {
      setError("The two passwords do not match.");
      return;
    }
    if (!supabase) {
      setError("Student accounts are being switched on — please check back shortly.");
      return;
    }
    setBusy(true);
    try {
      const { error: updateError } = await supabase.auth.updateUser({ password: newPassword });
      if (updateError) throw updateError;
      navigate("/");
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function forgotPassword() {
    // No cooldown before: after a link was sent the button stayed
    // live, so repeated taps sent the student reset email after
    // reset email. One link is enough — the button stays sent.
    if (resetBusy || resetSent) return;
    setError("");
    setResetSent(false);
    if (!/^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$/.test(email.trim())) {
      setError("Enter your email address first, then tap Forgot password.");
      return;
    }
    if (!supabase) {
      setError("Student accounts are being switched on — please check back shortly.");
      return;
    }
    setResetBusy(true);
    try {
      const { error: resetError } = await supabase.auth.resetPasswordForEmail(email.trim(), {
        redirectTo: `${window.location.origin}/signin`,
      });
      if (resetError) throw resetError;
      setResetSent(true);
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setResetBusy(false);
    }
  }

  async function submit(e) {
    e.preventDefault();
    // Entry guard: the button only disables after a re-render, so
    // two fast taps ran sign-in twice.
    if (busy) return;
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
    // Entry guard: a double-tap started Google sign-in twice.
    if (busy) return;
    setError("");
    if (!configured) {
      setError("Student accounts are being switched on — please check back shortly.");
      return;
    }
    setBusy(true);
    try {
      await signInGoogle();
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  // Back from the reset link: set the new password here.
  if (recoveryMode) {
    return (
      <div className="mx-auto max-w-sm space-y-5 pt-10">
        <h1 className="text-2xl font-bold">Set a new password</h1>
        <p className="text-neutral-500">
          You came from the password reset link. Choose a new password
          for your PulseMarket account.
        </p>

        <form onSubmit={saveNewPassword} className="space-y-3">
          <label className="block text-sm font-semibold">
            New password
            <input
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              type="password"
              placeholder="At least 6 characters"
              className={`${inputCls} mt-1`}
            />
          </label>
          <label className="block text-sm font-semibold">
            Confirm new password
            <input
              value={newConfirm}
              onChange={(e) => setNewConfirm(e.target.value)}
              type="password"
              placeholder="Repeat your new password"
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
            disabled={busy || !newPassword || !newConfirm}
          >
            {busy ? "Saving…" : "Save new password"}
          </PrimaryButton>
        </form>

        <GhostButton className="w-full" onClick={() => setRecoveryMode(false)}>
          Back to sign in
        </GhostButton>
      </div>
    );
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

      <GhostButton className="w-full" onClick={google} disabled={busy}>
        Continue with Google
      </GhostButton>

      <button
        type="button"
        onClick={forgotPassword}
        disabled={resetBusy || resetSent}
        className="w-full text-center text-sm font-semibold text-brown underline disabled:opacity-50"
      >
        {resetSent ? "Reset link sent ✓" : resetBusy ? "Sending…" : "Forgot your password?"}
      </button>
      {resetSent ? (
        <p className="rounded-xl bg-neutral-100 p-3 text-sm text-neutral-700 dark:bg-neutral-900 dark:text-neutral-300">
          Check your inbox — a password reset link is on its way to {email.trim()}.
        </p>
      ) : null}

      <p className="text-center text-sm text-neutral-500">
        New to PulseMarket?{" "}
        <Link to="/verify" className="font-semibold text-brown underline">
          Join & verify
        </Link>
      </p>
    </div>
  );
}
