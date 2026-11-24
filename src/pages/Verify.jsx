import { useState } from "react";
import { UNIVERSITIES } from "../lib/data";
import { getVerification, saveVerification } from "../lib/store";
import { GhostButton, PrimaryButton, inputCls } from "../components/ui";
import { openAuth } from "../lib/identity";

export default function Verify({ user }) {
  const [saved, setSaved] = useState(getVerification());
  const [email, setEmail] = useState(user?.email || "");
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

  function submit() {
    const rec = {
      university,
      studentEmail,
      studentId,
      status: "pending review",
      inviteCode: `PM-${Math.random().toString(36).slice(2, 8).toUpperCase()}`,
      submittedAt: new Date().toISOString(),
    };
    saveVerification(rec);
    setSaved(rec);
  }

  if (saved) {
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
            carry over. Your welcome email is queued for {studentEmail || email || "your email"}.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-5">
      <h1 className="text-2xl font-bold">Join & verify</h1>
      <p className="text-neutral-500">
        Create your account, then prove you are a real student. Your university
        and currency lock after verification.
      </p>

      <div className="space-y-2">
        <PrimaryButton className="w-full" onClick={() => openAuth("signup")}>
          Continue with Google
        </PrimaryButton>
        <GhostButton className="w-full" onClick={() => openAuth("login")}>
          I already have an account — sign in
        </GhostButton>
        <p className="text-center text-xs text-neutral-400">
          Sign-in opens the secure Netlify Identity window. If it does not open,
          sign-in is still being switched on for this site.
        </p>
      </div>

      <label className="block text-sm font-semibold">Email address — for your welcome email and receipts
        <input value={email} onChange={(e) => setEmail(e.target.value)} type="email" placeholder="you@example.com" className={`${inputCls} mt-1`} />
      </label>
      <label className="block text-sm font-semibold">University
        <select value={university} onChange={(e) => setUniversity(e.target.value)} className={`${inputCls} mt-1`}>
          {UNIVERSITIES.map((u) => <option key={u}>{u}</option>)}
        </select>
      </label>
      <label className="block text-sm font-semibold">Student email (optional)
        <input value={studentEmail} onChange={(e) => setStudentEmail(e.target.value)} type="email" placeholder="you@university.edu.ng" className={`${inputCls} mt-1`} />
      </label>
      <label className="block text-sm font-semibold">Student ID / matric number
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
        disabled={!email || !studentId}
        onClick={submit}
      >
        Review & submit
      </PrimaryButton>
      <p className="text-center text-xs text-neutral-400">
        By joining you agree to meet in safe places and never pay outside the
        app for shipped items.
      </p>
    </div>
  );
}
