// Milestone 6 — Wallet ledger. Balances are NEVER stored anywhere.
// They are computed only by SUM(amount) over the wallet_ledger rows,
// grouped by bucket, so the ledger is the single source of truth and a
// balance can never drift from the money movements behind it.
import { supabase } from "./supabase";

function dbError(err, where) {
  console.error(`[PulseMarket] ${where}:`, err?.message || err);
  return null;
}

export async function getBalances(userId) {
  if (!supabase || !userId) return { held: 0, available: 0 };
  const { data, error } = await supabase
    .from("wallet_ledger")
    .select("bucket, amount")
    .eq("user_id", userId);
  if (error) {
    dbError(error, "fetch wallet balances");
    return { held: 0, available: 0 };
  }
  const balances = { held: 0, available: 0 };
  for (const row of data || []) {
    if (row.bucket === "held" || row.bucket === "available") {
      balances[row.bucket] += Number(row.amount) || 0;
    }
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
