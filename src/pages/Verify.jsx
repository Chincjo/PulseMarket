// Join & verify — two steps, both separate from the home page:
// 1) Create a real account (email + password, or Google) with Supabase.
//    Supabase sends a confirmation email; the student clicks it, then signs in.
// 2) Prove student status (university, student email, student ID, ID photos).
// Only after step 2 does the home page and the rest of the app unlock.
// Real server-side document review lands in Milestone 3 — for now the
// submitted details are saved and the university locks.
import { useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { UNIVERSITIES } from "../lib/data";
import { getVerification, saveVerification } from "../lib/store";
import { GhostButton, PrimaryButton, inputCls } from "../components/ui";
import { useAuth } from "../lib/auth";

function friendlyError(err) {
  const msg = err?.message || "";
  if (/user already registered/i.test(msg))
    return "An account with that email already exists — please sign in instead.";
  if (/password/i.test(msg) && /at least|short/i.test(msg))
    return "Password must be at least 6 characters.";
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

export default function Verify({ onVerified }) {
  const { user, configured, signUpEmail, signInGoogle, signOut } = useAuth();
  const navigate = useNavigate();
  const [saved, setSaved] = useState(getVerification());

  // Step 1 — account creation.
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [awaitingConfirmation, setAwaitingConfirmation] = useState(false);

  // Step 2 — student verification.
  const [university, setUniversity] = useState(UNIVERSITIES[0]);
  const [studentEmail, setStudentEmail] = useState("");
  const [studentId, setStudentId] = useState("");
  const [idFront, setIdFront] = useState(null);
  const [idBack, setIdBack] = useState(null);

  function filePreview(e, set) {
    const f = e.target.files?.[0];
    if (!f) return;
    const r = new FileReader();
    r.onload = () => set(r.result);
    r.readAsDataURL(f);
  }

  async function createAccount(e) {
    e.preventDefault();
    setError("");
    if (!configured) {
      setError("Student accounts are being switched on — please check back shortly.");
      return;
    }
    if (password.length < 6) {
      setError("Password must be at least 6 characters.");
      return;
    }
    if (password !== confirm) {
      setError("The two passwords do not match.");
      return;
    }
    setBusy(true);
    try {
      const data = await signUpEmail(email.trim(), password);
      if (!data.session) setAwaitingConfirmation(true);
      // With a session (confirmation off), the auth listener signs the
      // student in and this page re-renders into step 2 automatically.
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

  function submitVerification() {
    const rec = {
      userId: user?.id || null,
      email: user?.email || email,
      university,
      studentEmail,
      studentId,
      status: "pending review",
      inviteCode: `PM-${Math.random().toString(36).slice(2, 8).toUpperCase()}`,
      submittedAt: new Date().toISOString(),
    };
    saveVerification(rec);
    setSaved(rec);
    onVerified?.(rec);
    navigate("/");
  }

  // Verification already submitted on this device.
  if (saved) {
    if (!user) {
      return (
        <div className="space-y-4 pt-10 text-center">
          <h1 className="text-2xl font-bold">Welcome back</h1>
          <p className="text-neutral-500">
            Your verification for {saved.university} is saved on this device.
            Sign in to continue to the app.
          </p>
          <Link to="/signin" className="inline-block">
            <PrimaryButton>Sign in</PrimaryButton>
          </Link>
        </div>
      );
    }
    return (
      <div className="space-y-4 pt-4">
        <h1 className="text-2xl font-bold">Verification {saved.status}</h1>
        <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
          <p><b>University:</b> {saved.university}</p>
          <p className="mt-1"><b>Student ID:</b> {saved.studentId || "—"}</p>
          <p className="mt-1"><b>Invite code:</b> {saved.inviteCode}</p>
          <p className="mt-2 text-neutral-500">
            Your university is now locked to {saved.university}. Real document
            review goes live with Milestone 3 — your details are saved and will
            carry over.
          </p>
        </div>
        <PrimaryButton className="w-full" onClick={() => navigate("/")}>
          Continue to the app
        </PrimaryButton>
      </div>
    );
  }

  // Step 2 — signed in, not verified yet: the verification form.
  if (user) {
    return (
      <div className="space-y-5">
        <h1 className="text-2xl font-bold">Verify you are a student</h1>
        <p className="text-neutral-500">
          Signed in as {user.email}. Prove you are a real student — your
          university and currency lock after verification.
        </p>

        <label className="block text-sm font-semibold">
          University
          <select value={university} onChange={(e) => setUniversity(e.target.value)} className={`${inputCls} mt-1`}>
            {UNIVERSITIES.map((u) => <option key={u}>{u}</option>)}
          </select>
        </label>
        <label className="block text-sm font-semibold">
          Student email (optional)
          <input value={studentEmail} onChange={(e) => setStudentEmail(e.target.value)} type="email" placeholder="you@university.edu.ng" className={`${inputCls} mt-1`} />
        </label>
        <label className="block text-sm font-semibold">
          Student ID / matric number
          <input value={studentId} onChange={(e) => setStudentId(e.target.value)} placeholder="e.g. U2026/04115" className={`${inputCls} mt-1`} />
        </label>
        <div className="grid grid-cols-2 gap-2">
          <label className="block rounded-2xl border border-dashed border-neutral-300 p-4 text-center text-sm dark:border-neutral-700">
            ID front
            <input type="file" accept="image/*" onChange={(e) => filePreview(e, setIdFront)} className="mt-2 block w-full text-xs" />
            {idFront ? <img src={idFront} alt="ID front" className="mt-2 h-20 w-full rounded-lg object-cover" /> : null}
          </label>
          <label className="block rounded-2xl border border-dashed border-neutral-300 p-4 text-center text-sm dark:border-neutral-700">
            ID back
            <input type="file" accept="image/*" onChange={(e) => filePreview(e, setIdBack)} className="mt-2 block w-full text-xs" />
            {idBack ? <img src={idBack} alt="ID back" className="mt-2 h-20 w-full rounded-lg object-cover" /> : null}
          </label>
        </div>

        <PrimaryButton
          className="w-full"
          disabled={!studentId}
          onClick={submitVerification}
        >
          Review & submit
        </PrimaryButton>
        <button
          className="w-full text-center text-sm text-neutral-500 underline"
          onClick={() => signOut()}
        >
          Not {user.email}? Sign out
        </button>
        <p className="text-center text-xs text-neutral-400">
          By joining you agree to meet in safe places and never pay outside the
          app for shipped items.
        </p>
      </div>
    );
  }

  // Waiting for the confirmation email to be clicked.
  if (awaitingConfirmation) {
    return (
      <div className="space-y-4 pt-10 text-center">
        <h1 className="text-2xl font-bold">Check your email</h1>
        <p className="text-neutral-500">
          We sent a confirmation link to {email}. Click it, then sign in — your
          verification form is next.
        </p>
        <Link to="/signin" className="inline-block">
          <PrimaryButton>I confirmed — sign in</PrimaryButton>
        </Link>
      </div>
    );
  }

  // Step 1 — no account yet: create one first.
  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-bold">Join & verify</h1>
      <p className="text-neutral-500">
        Create your account, then prove you are a real student. Your university
        and currency lock after verification.
      </p>

      <form onSubmit={createAccount} className="space-y-3">
        <label className="block text-sm font-semibold">
          Email address — for your welcome email and receipts
          <input value={email} onChange={(e) => setEmail(e.target.value)} type="email" placeholder="you@example.com" className={`${inputCls} mt-1`} />
        </label>
        <label className="block text-sm font-semibold">
          Password
          <input value={password} onChange={(e) => setPassword(e.target.value)} type="password" placeholder="At least 6 characters" className={`${inputCls} mt-1`} />
        </label>
        <label className="block text-sm font-semibold">
          Confirm password
          <input value={confirm} onChange={(e) => setConfirm(e.target.value)} type="password" placeholder="Repeat your password" className={`${inputCls} mt-1`} />
        </label>
        {error ? (
          <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
            {error}
          </p>
        ) : null}
        <PrimaryButton
          className="w-full"
          disabled={busy || !email || !password || !confirm}
        >
          {busy ? "Creating account…" : "Create account"}
        </PrimaryButton>
      </form>

      <GhostButton className="w-full" onClick={google}>
        Continue with Google
      </GhostButton>

      <p className="text-center text-sm text-neutral-500">
        Already have an account?{" "}
        <Link to="/signin" className="font-semibold text-brown underline">
          Sign in
        </Link>
      </p>
      <p className="text-center text-xs text-neutral-400">
        By joining you agree to meet in safe places and never pay outside the
        app for shipped items.
      </p>
    </div>
  );
}
