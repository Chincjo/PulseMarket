// Join & verify — two steps, both separate from the home page:
// 1) Create a real account (email + password, or Google) with Supabase.
//    Supabase sends a confirmation email; the student clicks it, then signs in.
// 2) Prove student status (university, student email, student ID, ID photos).
// Only after step 2 does the home page and the rest of the app unlock.
// Milestone 3: the submitted details are saved to the server
// (verifications table) as well as on the device, so they follow the
// student to any phone they sign in on. The university locks after submit.
// Milestone 17: the ID photos are uploaded FIRST, to the PRIVATE
// verification-ids bucket — never to a public bucket — and their storage
// paths go on the verification row with status 'pending review'. Only
// the team can approve (or reject) a row; a rejected student can submit
// again with new photos through the resubmit_verification RPC.
import { useEffect, useState } from "react";
import { Link, useNavigate } from "react-router-dom";
import { UNIVERSITY_NAMES } from "../lib/data";
import { getVerification, saveVerification } from "../lib/store";
import {
  fetchVerificationRow,
  fetchVerificationRowChecked,
  removeVerificationIdPhotos,
  replaceVerificationPhotos,
  resubmitVerification,
  saveVerificationRow,
  uploadVerificationIdPhotos,
} from "../lib/listings";
import { generateInviteCode } from "../lib/ratings";
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

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const MAX_FILE_MB = 10;

// Some Android browsers report no MIME type at all for a picked
// photo (f.type is ""), so a type-only check would let any file
// through. Fall back to the file extension when the type is empty.
const IMAGE_EXTENSIONS = [".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp"];
function isImageFile(f) {
  if (!f) return false;
  if (f.type) return f.type.startsWith("image/");
  const name = (f.name || "").toLowerCase();
  return IMAGE_EXTENSIONS.some((ext) => name.endsWith(ext));
}

// Milestone 19 (Decision 3): what the team said, in plain words,
// for each fixed rejection reason — shown to the rejected student
// so they know exactly what to fix before submitting again. A
// student rejected before reasons existed has no reason stored and
// gets the plain fallback below.
const REJECTION_MESSAGES = {
  blurry: "The team said: blurry photo — please upload a clearer photo of your ID.",
  "wrong document":
    "The team said: wrong document — please upload a photo of your student ID, not another document.",
  "name mismatch":
    "The team said: name mismatch — the name on your ID does not match your account details. Please check your details and upload the correct student ID.",
  expired:
    "The team said: expired ID — your student ID has expired. Please upload a current, valid student ID.",
  other:
    "The team said: please check your details and upload clear photos of both sides of your student ID.",
};

function rejectionMessage(reason) {
  return REJECTION_MESSAGES[reason] || "Your verification was not approved. Check your details and take clear photos of both sides of your student ID, then submit again.";
}

export default function Verify({ onVerified, initialVerification }) {
  const { user, configured, signUpEmail, signInGoogle, signOut } = useAuth();
  const navigate = useNavigate();
  // Seeded from the app's server-checked verification when App.jsx
  // mounts this page for a student under review — the page then
  // shows the under-review screen (with photo replace) at once
  // instead of flashing the submit form while its own server check
  // runs. Falls back to the device copy as before.
  const [saved, setSaved] = useState(initialVerification || getVerification());
  // The device copy may belong to ANOTHER student (shared phone,
  // account switched): its university, student ID and invite code
  // must never be shown or reused for this account. savedForUser
  // is null in that case, and the server check below replaces it
  // with this account's own row. Records saved before userId was
  // stored have no userId and keep the old behaviour.
  const savedForUser =
    saved && user?.id && saved.userId && saved.userId !== user.id ? null : saved;

  // Step 1 — account creation.
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [awaitingConfirmation, setAwaitingConfirmation] = useState(false);

  // Step 2 — student verification.
  // A rejected student submits again, so the form starts filled with
  // their saved details (university, student email, student ID and
  // invite code are kept — they are never changed on a re-submit).
  const [university, setUniversity] = useState(savedForUser?.university || UNIVERSITY_NAMES[0]);
  const [studentEmail, setStudentEmail] = useState(savedForUser?.studentEmail || "");
  const [studentId, setStudentId] = useState(savedForUser?.studentId || "");
  const [referralCode, setReferralCode] = useState(savedForUser?.referredBy || "");
  const [idFront, setIdFront] = useState(null);
  const [idBack, setIdBack] = useState(null);
  // The picked files themselves (the previews above are data URLs for
  // the <img> tags only — the files are what gets uploaded).
  const [idFrontFile, setIdFrontFile] = useState(null);
  const [idBackFile, setIdBackFile] = useState(null);
  const [formError, setFormError] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [checking, setChecking] = useState(false);
  // "Check again" used to go silent when the team had not approved
  // yet — the spinner just stopped and nothing said why.
  const [checkNote, setCheckNote] = useState("");

  // Milestone 19 (Decision 2): replacing ID photos while still
  // under review. Separate files from the submit form above — the
  // pending screen below is a different view, and a half-picked
  // replacement must never leak into a re-submit.
  const [replaceFront, setReplaceFront] = useState(null);
  const [replaceBack, setReplaceBack] = useState(null);
  const [replaceFrontFile, setReplaceFrontFile] = useState(null);
  const [replaceBackFile, setReplaceBackFile] = useState(null);
  const [replaceError, setReplaceError] = useState("");
  const [replaceDone, setReplaceDone] = useState("");
  const [replacing, setReplacing] = useState(false);

  // Milestone 17: the device copy can be stale — the team may have
  // approved or rejected this student since it was saved. When the
  // student is signed in, the server row wins, so a rejected student
  // is offered the form again instead of a stale "under review"
  // screen, and an approved student is not asked to submit again.
  // A failed check changes nothing: the device copy stays.
  useEffect(() => {
    if (!user?.id) return;
    // Another student's device copy on this phone: drop it now —
    // fields, state and storage — before it can pre-fill this
    // student's form or lend them the other student's invite code.
    // The server fetch below then loads this account's own row.
    if (saved && !savedForUser) {
      saveVerification(null);
      setSaved(null);
      setUniversity(UNIVERSITY_NAMES[0]);
      setStudentEmail("");
      setStudentId("");
      setReferralCode("");
    }
    let cancelled = false;
    fetchVerificationRow(user.id)
      .then((row) => {
        if (cancelled || !row) return;
        const rec = {
          userId: row.userId,
          email: user.email,
          university: row.university,
          studentEmail: row.studentEmail,
          studentId: row.studentId,
          status: row.status,
          inviteCode: row.inviteCode,
          submittedAt: row.submittedAt,
          idFrontUrl: row.idFrontUrl || null,
          idBackUrl: row.idBackUrl || null,
          // Milestone 19: why the team rejected this student, if they
          // did, and their note — carried on the device copy so the
          // form below can show it without another server round trip.
          rejectionReason: row.rejectionReason || null,
          rejectionNote: row.rejectionNote || null,
          // The server row carries no referrer — keep the device copy's,
          // but only when that copy is this student's own.
          referredBy: savedForUser?.referredBy ?? null,
        };
        saveVerification(rec);
        setSaved(rec);
        if (row.status === "rejected") {
          // Pre-fill the form for the re-submit — only where the
          // student has not already typed something.
          setUniversity((prev) => (prev === UNIVERSITY_NAMES[0] ? row.university : prev));
          setStudentEmail((prev) => prev || row.studentEmail || "");
          setStudentId((prev) => prev || row.studentId || "");
        }
      })
      // Milestone 20 (APP-13): a failed server check changes
      // nothing — the device copy stays — but the rejection must
      // be caught, or the failed check is an unhandled rejection.
      .catch(() => {});
    return () => {
      cancelled = true;
    };
  }, [user?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  function filePreview(e, setPreview, setFile) {
    const f = e.target.files?.[0];
    if (!f) return;
    if (!isImageFile(f)) {
      setFormError("That file is not a photo — take a photo of your student ID.");
      e.target.value = "";
      setPreview(null);
      setFile(null);
      return;
    }
    if (f.size > MAX_FILE_MB * 1024 * 1024) {
      setFormError(`That photo is too big — keep ID photos under ${MAX_FILE_MB}MB.`);
      e.target.value = "";
      setPreview(null);
      setFile(null);
      return;
    }
    setFormError("");
    setFile(f);
    const r = new FileReader();
    r.onload = () => setPreview(r.result);
    r.readAsDataURL(f);
  }

  async function createAccount(e) {
    e.preventDefault();
    // Entry guard: a double-tap fired signUpEmail twice and the
    // second call failed misleadingly with "user already registered".
    if (busy) return;
    setError("");
    if (!configured) {
      setError("Student accounts are being switched on — please check back shortly.");
      return;
    }
    if (!EMAIL_RE.test(email.trim())) {
      setError("Enter a valid email address.");
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
      if (!data?.session) setAwaitingConfirmation(true);
      // With a session (confirmation off), the auth listener signs the
      // student in and this page re-renders into step 2 automatically.
    } catch (err) {
      setError(friendlyError(err));
    } finally {
      setBusy(false);
    }
  }

  async function google() {
    // Entry guard, same as createAccount above: a double-tap
    // started Google sign-in twice.
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

  async function submitVerification() {
    // No busy guard before: a double-tap generated TWO different
    // invite codes and saved the verification twice — the local record
    // could end up holding a different invite code from the server row.
    if (submitting) return;
    setFormError("");
    // Before this fix a student ID of only spaces passed (the button
    // only checked the raw string was non-empty) and a mistyped
    // student email was saved without complaint — and step 2 had no
    // error display at all, so a failed save failed silently.
    const cleanStudentId = studentId.trim();
    if (cleanStudentId.length < 2 || cleanStudentId.length > 50) {
      setFormError("Enter your student ID / matric number (2–50 characters).");
      return;
    }
    const cleanStudentEmail = studentEmail.trim();
    if (cleanStudentEmail && !EMAIL_RE.test(cleanStudentEmail)) {
      setFormError("That student email does not look right — check it and try again.");
      return;
    }
    if (cleanStudentEmail.length > 120) {
      setFormError("That student email is too long.");
      return;
    }
    // Milestone 17: both sides of the student ID are needed — the
    // team cannot approve a student they cannot check. Refuse here,
    // plainly, instead of saving a photo-less row that would sit in
    // "pending review" forever with nothing to review.
    if (!idFrontFile || !idBackFile) {
      setFormError("Add a photo of the front and back of your student ID — the team checks them before approving you.");
      return;
    }
    if (!user?.id) {
      setFormError("Sign in first, then submit your verification.");
      return;
    }
    setSubmitting(true);
    try {
      // Fresh server check first: the device copy can be stale, and
      // the right path depends on the server status — a first submit,
      // a re-submit after a rejection, or nothing at all because the
      // student is already approved or already under review.
      // Milestone 22: a FAILED check must never look like "no row".
      // It used to fall through as a first-time submitter, so an
      // already-approved student could upload new photos and end up
      // "pending review" on the device while the team still saw the
      // old row. Refuse plainly instead — the student tries again
      // once the check works.
      let serverRow = null;
      try {
        const checked = await fetchVerificationRowChecked(user.id);
        if (checked.failed) {
          setFormError("Could not check your verification — check your connection and try again.");
          return;
        }
        serverRow = checked.row;
      } catch {
        setFormError("Could not check your verification — check your connection and try again.");
        return;
      }
      const serverStatus = serverRow?.status || null;
      if (serverStatus === "approved") {
        // Already approved — nothing to submit. Sync the device copy
        // and go to the app instead of saving a second row.
        const rec = {
          userId: user.id,
          email: user.email,
          university: serverRow.university,
          studentEmail: serverRow.studentEmail,
          studentId: serverRow.studentId,
          status: "approved",
          inviteCode: serverRow.inviteCode,
          referredBy: savedForUser?.referredBy ?? null,
          submittedAt: serverRow.submittedAt,
          idFrontUrl: serverRow.idFrontUrl || null,
          idBackUrl: serverRow.idBackUrl || null,
          rejectionReason: null,
          rejectionNote: null,
        };
        saveVerification(rec);
        setSaved(rec);
        onVerified?.(rec);
        navigate("/");
        return;
      }
      if (serverStatus === "pending review") {
        // Already waiting — do not upload again and do not save a
        // second row. Sync the device copy and say so plainly.
        const rec = {
          userId: user.id,
          email: user.email,
          university: serverRow.university,
          studentEmail: serverRow.studentEmail,
          studentId: serverRow.studentId,
          status: "pending review",
          inviteCode: serverRow.inviteCode,
          referredBy: savedForUser?.referredBy ?? null,
          submittedAt: serverRow.submittedAt,
          idFrontUrl: serverRow.idFrontUrl || null,
          idBackUrl: serverRow.idBackUrl || null,
          rejectionReason: null,
          rejectionNote: null,
        };
        saveVerification(rec);
        setSaved(rec);
        onVerified?.(rec);
        // No form error here: onVerified moves the app to its
        // "under review" screen, which carries the message.
        return;
      }
      // Rejected on the server, or rejected on the device copy when
      // the server could not be reached: submit again with new
      // photos. The invite code and referrer are kept from the first
      // submit — a re-submit never changes who the student is or who
      // invited them.
      const isResubmit =
        serverStatus === "rejected" || (!serverRow && savedForUser?.status === "rejected");
      const keptCode = serverRow?.inviteCode || savedForUser?.inviteCode || null;
      const inviteCode =
        isResubmit && keptCode ? keptCode : generateInviteCode();
      // Milestone 11: a referral code is accepted only in the real
      // PM-XXXXXX shape; anything else is ignored, never blocks joining.
      // Your own invite code can never count as your referrer — the code
      // is generated first so it can be compared here, and
      // saveVerificationRow drops a self-referral too.
      const cleanReferral = referralCode.trim().toUpperCase();
      if (cleanReferral && cleanReferral === inviteCode) {
        setFormError("That is your own invite code — ask the student who invited you for theirs.");
        return;
      }
      const referredBy = isResubmit
        ? savedForUser?.referredBy || null
        : /^PM-[A-HJ-NP-Z2-9]{6}$/.test(cleanReferral)
          ? cleanReferral
          : null;
      // Milestone 17: the ID photos go up FIRST, to the private
      // verification-ids bucket. If either upload fails, nothing is
      // saved — no row is ever written claiming photos exist when
      // they do not.
      let photoPaths;
      try {
        photoPaths = await uploadVerificationIdPhotos(user.id, idFrontFile, idBackFile);
      } catch {
        setFormError("Your ID photos could not be uploaded. Please check your connection and try again.");
        return;
      }
      const rec = {
        userId: user.id,
        email: user.email,
        // On a re-submit the university, student email and student
        // ID are locked server-side (the resubmit RPC only moves
        // status + photos), so the local record must carry the
        // server's values, not whatever was typed in the form —
        // otherwise the device copy claims a university the server
        // never recorded.
        university: isResubmit ? serverRow?.university || university : university,
        studentEmail: isResubmit
          ? serverRow?.studentEmail || cleanStudentEmail
          : cleanStudentEmail,
        studentId: isResubmit ? serverRow?.studentId || cleanStudentId : cleanStudentId,
        status: "pending review",
        inviteCode,
        referredBy,
        submittedAt: new Date().toISOString(),
        idFrontUrl: photoPaths.frontPath,
        idBackUrl: photoPaths.backPath,
        // Back under review — any earlier rejection reason is spent.
        rejectionReason: null,
        rejectionNote: null,
      };
      if (isResubmit) {
        // Back to 'pending review' through the RPC — the app never
        // writes a status itself. If it fails, remove the new photos
        // again so they do not sit orphaned in the bucket.
        try {
          await resubmitVerification(photoPaths.frontPath, photoPaths.backPath);
        } catch (err) {
          await removeVerificationIdPhotos([photoPaths.frontPath, photoPaths.backPath]);
          setFormError(
            err?.message ||
              "Could not submit your verification again. Please check your connection and try again."
          );
          return;
        }
        saveVerification(rec);
        setSaved(rec);
        onVerified?.(rec);
        navigate("/");
        return;
      }
      // First submit: save to the server FIRST. The device copy
      // must never claim a verification the server does not have,
      // and a failed save used to leave the photos orphaned in the
      // bucket with a local record saying "pending review". If the
      // save fails, remove the photos just uploaded and say so
      // plainly — the student can try again. (The old code set the
      // local record and navigated on before saving, and swallowed
      // the server error.)
      let savedToServer = false;
      try {
        savedToServer = await saveVerificationRow(user.id, rec);
      } catch {
        savedToServer = false;
      }
      if (!savedToServer) {
        await removeVerificationIdPhotos([photoPaths.frontPath, photoPaths.backPath]);
        setFormError("Could not save your verification. Please check your connection and try again.");
        return;
      }
      saveVerification(rec);
      setSaved(rec);
      onVerified?.(rec);
      navigate("/");
    } finally {
      setSubmitting(false);
    }
  }

  // A student under review asks the server again instead of signing
  // out and back in — the team may have approved them since this
  // page loaded. A fresh 'approved' row opens the app at once.
  async function checkStatus() {
    if (!user?.id || checking) return;
    setChecking(true);
    setCheckNote("");
    try {
      const row = await fetchVerificationRow(user.id);
      if (!row) {
        setCheckNote("Could not check your verification — check your connection and try again later.");
        return;
      }
      const rec = {
        userId: row.userId,
        email: user.email,
        university: row.university,
        studentEmail: row.studentEmail,
        studentId: row.studentId,
        status: row.status,
        inviteCode: row.inviteCode,
        referredBy: savedForUser?.referredBy ?? null,
        submittedAt: row.submittedAt,
        idFrontUrl: row.idFrontUrl || null,
        idBackUrl: row.idBackUrl || null,
        rejectionReason: row.rejectionReason || null,
        rejectionNote: row.rejectionNote || null,
      };
      saveVerification(rec);
      setSaved(rec);
      onVerified?.(rec);
      if (row.status === "approved") navigate("/");
      else setCheckNote("Still under review — the team has not approved it yet. Try again later.");
    } finally {
      setChecking(false);
    }
  }

  // Milestone 19 (Decision 2): pick one replacement photo while
  // under review. Same checks as the submit form: a photo, under
  // the size limit. A bad pick clears that side only.
  function pickReplacePhoto(e, setPreview, setFile) {
    const f = e.target.files?.[0];
    if (!f) return;
    if (!isImageFile(f)) {
      setReplaceError("That file is not a photo — take a photo of your student ID.");
      e.target.value = "";
      setPreview(null);
      setFile(null);
      return;
    }
    if (f.size > MAX_FILE_MB * 1024 * 1024) {
      setReplaceError(`That photo is too big — keep ID photos under ${MAX_FILE_MB}MB.`);
      e.target.value = "";
      setPreview(null);
      setFile(null);
      return;
    }
    setReplaceError("");
    setReplaceDone("");
    setFile(f);
    const r = new FileReader();
    r.onload = () => setPreview(r.result);
    r.readAsDataURL(f);
  }

  // Milestone 19 (Decision 2): replace both ID photos while still
  // under review. The helper uploads first and only then calls the
  // server — if anything fails, the row is untouched and the old
  // photos stay the ones under review. Status stays 'pending
  // review'; the team reviews the new photos.
  async function replacePhotos() {
    if (replacing) return;
    setReplaceError("");
    setReplaceDone("");
    if (!replaceFrontFile || !replaceBackFile) {
      setReplaceError("Add a photo of the front and back of your student ID.");
      return;
    }
    if (!user?.id) {
      setReplaceError("Sign in first, then replace your photos.");
      return;
    }
    setReplacing(true);
    try {
      const photoPaths = await replaceVerificationPhotos(
        user.id,
        replaceFrontFile,
        replaceBackFile
      );
      const rec = {
        ...saved,
        status: "pending review",
        idFrontUrl: photoPaths.frontPath,
        idBackUrl: photoPaths.backPath,
      };
      saveVerification(rec);
      setSaved(rec);
      setReplaceFront(null);
      setReplaceBack(null);
      setReplaceFrontFile(null);
      setReplaceBackFile(null);
      setReplaceDone("Photos replaced — the team will review your new photos. You are still in the queue.");
    } catch (err) {
      setReplaceError(
        err?.message || "Could not replace your ID photos. Please check your connection and try again."
      );
    } finally {
      setReplacing(false);
    }
  }

  // Verification already submitted on this device, for this
  // student — a copy belonging to another student never renders
  // here (see savedForUser above).
  if (savedForUser) {
    const saved = savedForUser;
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
    // Approved: nothing to do again — straight into the app.
    if (saved.status === "approved") {
      return (
        <div className="space-y-4 pt-4">
          <h1 className="text-2xl font-bold">Verification approved</h1>
          <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
            <p><b>University:</b> {saved.university}</p>
            <p className="mt-1"><b>Student ID:</b> {saved.studentId || "—"}</p>
            <p className="mt-1"><b>Invite code:</b> {saved.inviteCode}</p>
            <p className="mt-2 text-neutral-500">
              Your university is now locked to {saved.university}. Your details
              are saved on PulseMarket&apos;s server, so they follow you to any
              phone you sign in on.
            </p>
          </div>
          <PrimaryButton className="w-full" onClick={() => navigate("/")}>
            Continue to the app
          </PrimaryButton>
        </div>
      );
    }
    // Under review (or any status that is not approved or rejected):
    // plain waiting state, no way into the app from here, and no
    // second submit — the team already has this one. "Check again"
    // asks the server in case they have approved it since.
    // Milestone 19 (Decision 2): a student still waiting CAN
    // replace their ID photos — e.g. they realised the first ones
    // were blurry. The new photos go up first and the server swaps
    // them in; status stays 'pending review'.
    // A rejected student does NOT land here: they fall through to
    // the form below and submit again with new photos.
    if (saved.status !== "rejected") {
      return (
        <div className="space-y-4 pt-4">
          <h1 className="text-2xl font-bold">Your verification is under review</h1>
          <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
            <p><b>University:</b> {saved.university}</p>
            <p className="mt-1"><b>Student ID:</b> {saved.studentId || "—"}</p>
            <p className="mt-2 text-neutral-500">
              Thanks — we have your student details and ID photos. The
              PulseMarket team is checking them. You will be able to post
              items and chat with sellers once you are approved.
            </p>
          </div>
          <PrimaryButton className="w-full" disabled={checking} onClick={checkStatus}>
            {checking ? "Checking…" : "Check again — I may be approved now"}
          </PrimaryButton>
          {checkNote ? (
            <p className="rounded-xl bg-neutral-100 p-3 text-sm text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200">
              {checkNote}
            </p>
          ) : null}
          <div className="rounded-2xl border border-neutral-200 p-4 text-sm dark:border-neutral-800">
            <p className="font-semibold">Photos not clear?</p>
            <p className="mt-1 text-neutral-500">
              You can replace your ID photos while you wait — the team
              will review the new ones.
            </p>
            <div className="mt-3 grid grid-cols-2 gap-2">
              <label className="block rounded-2xl border border-dashed border-neutral-300 p-4 text-center text-sm dark:border-neutral-700">
                ID front
                <input type="file" accept="image/*" onChange={(e) => pickReplacePhoto(e, setReplaceFront, setReplaceFrontFile)} className="mt-2 block w-full text-xs" />
                {replaceFront ? <img src={replaceFront} alt="New ID front" className="mt-2 h-20 w-full rounded-lg object-cover" /> : null}
              </label>
              <label className="block rounded-2xl border border-dashed border-neutral-300 p-4 text-center text-sm dark:border-neutral-700">
                ID back
                <input type="file" accept="image/*" onChange={(e) => pickReplacePhoto(e, setReplaceBack, setReplaceBackFile)} className="mt-2 block w-full text-xs" />
                {replaceBack ? <img src={replaceBack} alt="New ID back" className="mt-2 h-20 w-full rounded-lg object-cover" /> : null}
              </label>
            </div>
            {replaceError ? (
              <p className="mt-3 rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
                {replaceError}
              </p>
            ) : null}
            {replaceDone ? (
              <p className="mt-3 rounded-xl bg-neutral-100 p-3 text-sm text-neutral-700 dark:bg-neutral-800 dark:text-neutral-200">
                {replaceDone}
              </p>
            ) : null}
            <button
              className="mt-3 w-full rounded-xl border border-neutral-300 px-4 py-2 text-sm font-semibold dark:border-neutral-700"
              disabled={!replaceFrontFile || !replaceBackFile || replacing}
              onClick={replacePhotos}
            >
              {replacing ? "Replacing…" : "Replace photos"}
            </button>
          </div>
          <button
            className="w-full text-center text-sm text-neutral-500 underline"
            onClick={() => signOut()}
          >
            Not {user.email}? Sign out
          </button>
        </div>
      );
    }
  }

  // Step 2 — signed in, not verified yet (or rejected and submitting
  // again): the verification form.
  if (user) {
    const isResubmitForm = savedForUser?.status === "rejected";
    return (
      <div className="space-y-5">
        <h1 className="text-2xl font-bold">
          {isResubmitForm ? "Submit your verification again" : "Verify you are a student"}
        </h1>
        {isResubmitForm ? (
          <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
            {rejectionMessage(saved?.rejectionReason)}
            {saved?.rejectionNote ? (
              <>
                <br />
                Note from the team: &ldquo;{saved.rejectionNote}&rdquo;
              </>
            ) : null}
            <br />
            Check your details and take clear photos of both sides of
            your student ID, then submit again. Your university,
            student ID and invite code stay the same.
          </p>
        ) : (
          <p className="text-neutral-500">
            Signed in as {user.email}. Prove you are a real student — your
            university and currency lock after verification.
          </p>
        )}

        <label className="block text-sm font-semibold">
          University
          <select value={university} onChange={(e) => setUniversity(e.target.value)} disabled={isResubmitForm} className={`${inputCls} mt-1`}>
            {UNIVERSITY_NAMES.map((u) => <option key={u}>{u}</option>)}
          </select>
        </label>
        <label className="block text-sm font-semibold">
          Student email (optional)
          <input value={studentEmail} onChange={(e) => setStudentEmail(e.target.value)} type="email" placeholder="you@university.edu.ng" disabled={isResubmitForm} className={`${inputCls} mt-1`} />
        </label>
        <label className="block text-sm font-semibold">
          Student ID / matric number
          <input value={studentId} onChange={(e) => setStudentId(e.target.value)} maxLength={50} placeholder="e.g. U2026/04115" disabled={isResubmitForm} className={`${inputCls} mt-1`} />
        </label>
        <label className="block text-sm font-semibold">
          Invite code (optional) — if a friend invited you
          <input value={referralCode} onChange={(e) => setReferralCode(e.target.value)} maxLength={9} placeholder="e.g. PM-AB12CD" disabled={isResubmitForm} className={`${inputCls} mt-1`} />
        </label>
        <div className="grid grid-cols-2 gap-2">
          <label className="block rounded-2xl border border-dashed border-neutral-300 p-4 text-center text-sm dark:border-neutral-700">
            ID front
            <input type="file" accept="image/*" onChange={(e) => filePreview(e, setIdFront, setIdFrontFile)} className="mt-2 block w-full text-xs" />
            {idFront ? <img src={idFront} alt="ID front" className="mt-2 h-20 w-full rounded-lg object-cover" /> : null}
          </label>
          <label className="block rounded-2xl border border-dashed border-neutral-300 p-4 text-center text-sm dark:border-neutral-700">
            ID back
            <input type="file" accept="image/*" onChange={(e) => filePreview(e, setIdBack, setIdBackFile)} className="mt-2 block w-full text-xs" />
            {idBack ? <img src={idBack} alt="ID back" className="mt-2 h-20 w-full rounded-lg object-cover" /> : null}
          </label>
        </div>
        {!idFrontFile || !idBackFile ? (
          <p className="text-sm text-neutral-500">
            Photos of the front and back of your student ID are needed — the
            team checks them before approving you.
          </p>
        ) : null}

        {formError ? (
          <p className="rounded-xl bg-red-50 p-3 text-sm text-red-700 dark:bg-red-950 dark:text-red-200">
            {formError}
          </p>
        ) : null}

        <PrimaryButton
          className="w-full"
          disabled={!studentId.trim() || !idFrontFile || !idBackFile || submitting}
          onClick={submitVerification}
        >
          {submitting ? "Submitting…" : isResubmitForm ? "Submit again" : "Review & submit"}
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
