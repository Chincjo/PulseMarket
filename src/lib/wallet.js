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

// Newest first, at most 200 rows. The wallet page renders every row,
// so an unbounded fetch grows with every order the student ever has.
export async function fetchLedger(userId) {
  if (!supabase || !userId) return [];
  const { data, error } = await supabase
    .from("wallet_ledger")
    .select("*, orders(code)")
    .eq("user_id", userId)
    .order("created_at", { ascending: false })
    .limit(200);
  if (error) {
    dbError(error, "fetch wallet ledger");
    return [];
  }
  return (data || []).map((row) => ({
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
}
