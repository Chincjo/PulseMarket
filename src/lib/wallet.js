// Milestone 6 — Wallet ledger. Balances are NEVER stored anywhere.
// They are computed only by SUM(amount) over the wallet_ledger rows,
// grouped by bucket, so the ledger is the single source of truth and a
// balance can never drift from the money movements behind it.
import { supabase } from "./supabase";

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

// Morning deep check 2026-11-28: the same reads as getBalances /
// fetchLedger, but the caller can tell a FAILED read apart from an
// empty wallet. The old functions returned 0 / [] on ANY error, so
// a network blip or a missing table made a funded wallet look
// empty — and a seller could think they had nothing to withdraw.
// Wallet.jsx uses these; other callers keep the lenient versions.
export async function getBalancesChecked(userId) {
  if (!supabase || !userId) return { balances: { held: 0, available: 0 }, failed: true };
  try {
    const { data, error } = await supabase.rpc("get_wallet_balances", {
      p_user_id: userId,
    });
    if (error) throw error;
    const balances = { held: 0, available: 0 };
    for (const row of data || []) {
      if (row.bucket === "held" || row.bucket === "available") {
        balances[row.bucket] = Number(row.balance) || 0;
      }
    }
    return { balances, failed: false };
  } catch (err) {
    console.warn(
      "[PulseMarket] get_wallet_balances RPC failed — using client-side sum:",
      err?.message || err
    );
  }
  const balances = { held: 0, available: 0 };
  const PAGE = 1000;
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from("wallet_ledger")
      .select("bucket, amount")
      .eq("user_id", userId)
      .range(from, from + PAGE - 1);
    if (error) {
      dbError(error, "fetch wallet balances");
      return { balances: { held: 0, available: 0 }, failed: true };
    }
    for (const row of data || []) {
      if (row.bucket === "held" || row.bucket === "available") {
        balances[row.bucket] += Number(row.amount) || 0;
      }
    }
    if (!data || data.length < PAGE) break;
  }
  return { balances, failed: false };
}

export async function getBalances(userId) {
  if (!supabase || !userId) return { held: 0, available: 0 };
  // Milestone 19: server-side sums via the get_wallet_balances RPC
  // (supabase/milestone-18.sql §11) instead of fetching every ledger
  // row and summing client-side. The RPC returns one row per bucket:
  // [{ bucket: "held", balance: 123 }, ...]. If the RPC call fails
  // (for example the milestone-18 SQL has not been run yet, so the
  // function does not exist), fall back to the old client-side sum
  // below so the wallet still shows a balance.
  try {
    const { data, error } = await supabase.rpc("get_wallet_balances", {
      p_user_id: userId,
    });
    if (error) throw error;
    const balances = { held: 0, available: 0 };
    for (const row of data || []) {
      if (row.bucket === "held" || row.bucket === "available") {
        balances[row.bucket] = Number(row.balance) || 0;
      }
    }
    return balances;
  } catch (err) {
    console.warn(
      "[PulseMarket] get_wallet_balances RPC failed — using client-side sum:",
      err?.message || err
    );
  }
  // Milestone 20 (APP-15): the old fallback read had NO limit, so
  // PostgREST silently stopped at its 1000-row default and the
  // wallet summed a truncated ledger. Page in 1000-row ranges
  // until a short page, so every row is summed.
  const balances = { held: 0, available: 0 };
  const PAGE = 1000;
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await supabase
      .from("wallet_ledger")
      .select("bucket, amount")
      .eq("user_id", userId)
      .range(from, from + PAGE - 1);
    if (error) {
      dbError(error, "fetch wallet balances");
      return { held: 0, available: 0 };
    }
    for (const row of data || []) {
      if (row.bucket === "held" || row.bucket === "available") {
        balances[row.bucket] += Number(row.amount) || 0;
      }
    }
    if (!data || data.length < PAGE) break;
  }
  return balances;
}

// Newest first, at most 200 rows per page. Pass `before` (a
// created_at value from the last row) to fetch the next page —
// without it a student with more than 200 ledger rows silently
// sees only the newest 200. The returned array carries `hasMore`
// (true when a full page came back, so another page may exist).
export async function fetchLedger(userId, { before } = {}) {
  if (!supabase || !userId) return [];
  let query = supabase
    .from("wallet_ledger")
    .select("*, orders(code)")
    .eq("user_id", userId)
    .order("created_at", { ascending: false });
  if (before) query = query.lt("created_at", before);
  const { data, error } = await query.limit(200);
  if (error) {
    dbError(error, "fetch wallet ledger");
    return [];
  }
  const rows = (data || []).map((row) => ({
    id: row.id,
    orderId: row.order_id,
    orderCode: row.orders?.code || null,
    userId: row.user_id,
    bucket: row.bucket,
    kind: row.kind,
    amount: row.amount,
    note: row.note,
    createdAt: row.created_at,
  }));
  rows.hasMore = (data || []).length === 200;
  return rows;
}

// Morning deep check 2026-11-28: checked version of fetchLedger —
// the caller can tell a failed read apart from an empty ledger
// (the plain version returns [] on error).
export async function fetchLedgerChecked(userId, { before } = {}) {
  if (!supabase || !userId) return { rows: [], failed: true };
  let query = supabase
    .from("wallet_ledger")
    .select("*, orders(code)")
    .eq("user_id", userId)
    .order("created_at", { ascending: false });
  if (before) query = query.lt("created_at", before);
  const { data, error } = await query.limit(200);
  if (error) {
    dbError(error, "fetch wallet ledger");
    return { rows: [], failed: true };
  }
  const rows = (data || []).map((row) => ({
    id: row.id,
    orderId: row.order_id,
    orderCode: row.orders?.code || null,
    userId: row.user_id,
    bucket: row.bucket,
    kind: row.kind,
    amount: row.amount,
    note: row.note,
    createdAt: row.created_at,
  }));
  rows.hasMore = (data || []).length === 200;
  return { rows, failed: false };
}
