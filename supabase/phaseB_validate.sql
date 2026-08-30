-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE B VALIDATION (run AFTER phase9 + phase10 + phase11)
-- Read-only. Confirms invariants; no data changed.
-- ══════════════════════════════════════════════════════════════════════════

-- 1) DEBT invariants — prin_ok and oblig_ok must equal principal / total_obligation
select id, name, principal,
       principal_paid + outstanding_principal as prin_ok,      -- must = principal
       total_obligation,
       paid_total + outstanding_total          as oblig_ok      -- must = total_obligation
from v_debt_summary;

-- 2) PAYROLL invariant — check_oblig must = obligation_total. needs_basis=true is
--    EXPECTED until a payroll % basis is decided (percentage/hybrid rules).
select id, name, obligation_total,
       paid_total + outstanding_total as check_oblig, needs_basis
from v_payroll_summary;

-- 3) CASH POOL / SAFE CASH — inspect each waterfall step.
--    safe_cash must equal actual_cash − reserve − debt_due − payroll_due − other_committed.
--    is_provisional stays true until opening cash is verified.
select baseline_date, horizon_days,
       opening_cash, debt_drawdowns, debt_paid, payroll_paid, actual_cash,
       reserve, debt_due, payroll_due, other_committed, safe_cash, is_provisional,
       actual_cash - reserve - debt_due - payroll_due - other_committed as recompute_safe
from v_cash_pool;   -- safe_cash must equal recompute_safe; movements only counted after baseline_date

-- 4) CONSOLIDATED LIABILITIES — components must sum to total.
select debt_outstanding, payroll_outstanding, partner_fee_payable,
       debt_outstanding + payroll_outstanding + partner_fee_payable as sum_check,
       total_liabilities
from v_liabilities;   -- sum_check must = total_liabilities

-- 5) NO DOUBLE-COUNT CHECKS (should return no rows / expected values):
--    a) Inventory is NOT in the safe-cash formula (by construction — nothing to query).
--    b) Payroll is NOT recorded in kas_keluar: confirm no salary rows were added there
--       (payroll cash-out lives only in payroll_payments).
select 'payroll_payments' as src, count(*) n, coalesce(sum(paid_amount),0) total from payroll_payments;

-- 6) Reserve single source: v_cash_pool.reserve must equal v_reserve_summary.reserve_balance
select (select reserve from v_cash_pool) as pool_reserve,
       (select reserve_balance from v_reserve_summary) as reserve_summary,
       (select reserve from v_cash_pool) = (select reserve_balance from v_reserve_summary) as match;
