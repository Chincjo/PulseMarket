export function load(key, fallback) {
  try {
    const raw = localStorage.getItem(key);
    return raw ? JSON.parse(raw) : fallback;
  } catch {
    return fallback;
  }
}

export function save(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // storage full or unavailable — keep in-memory only
  }
}

// Legacy device drafts — Milestone 4 moved publishing to the server
// (Supabase `listings` table). These helpers are no longer used by any page
// and are kept only so old installs do not break on upgrade.
export function getDrafts() {
  return load("pm-drafts", []);
}
export function saveDrafts(drafts) {
  save("pm-drafts", drafts);
}
export function addDraft(draft) {
  const drafts = getDrafts();
  drafts.unshift({ ...draft, id: `DRAFT-${Date.now().toString(36)}`, createdAt: new Date().toISOString() });
  saveDrafts(drafts);
  return drafts[0];
}
export function deleteDraft(id) {
  saveDrafts(getDrafts().filter((d) => d.id !== id));
}

// App settings: appearance + notification toggles.
export function getSettings() {
  return load("pm-settings", {
    theme: "system", // system | light | dark
    background: "system", // system | white | black | brown
    notifications: { priceDrops: true, checkpoints: true, disputes: true, ratings: true },
    verifiedOnlyChat: false,
  });
}
export function saveSettings(s) {
  save("pm-settings", s);
}

// Student verification record (server copy lands in Milestone 3; the
// device copy stays as the offline fallback).
export function getVerification() {
  return load("pm-verification", null);
}
export function saveVerification(v) {
  save("pm-verification", v);
}
