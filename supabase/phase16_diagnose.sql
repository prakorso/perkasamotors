-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — D6 RECONCILIATION DIAGNOSTIC  (READ-ONLY; no data/legacy change)
-- Outputs the three all-time values independently + the exact per-unit difference
-- between the STORED legacy net (keuntungan_bersih) and the VALIDATED computed
-- profit (revenue − unit_cost − fixed_fees) that v_pnl uses.
-- ══════════════════════════════════════════════════════════════════════════

-- (1) The three values, same all-time scope
select
  (fn_pnl('1900-01-01', current_date)->>'unit_retained')::numeric              as fn_pnl_unit_retained,
  (select sum(retained_profit) from v_unit_pnl_unified where source='legacy')  as vupu_legacy_retained,
  (select realized_unit_profit from v_pnl)                                     as v_pnl_realized,
  (select total_retained from v_retained_profit)                              as retained_total,
  (select sum(retained_profit) from v_unit_pnl_unified where source='legacy')
    - (select realized_unit_profit from v_pnl)                               as legacy_basis_diff;

-- (2) Which legacy units differ (stored keuntungan_bersih vs computed) and by how much
select e.id, e.nama,
  coalesce(e.realized_profit,0)                    as keuntungan_bersih_stored,
  (e.revenue - e.unit_cost - e.fixed_fees)         as computed_profit,
  coalesce(e.realized_profit,0) - (e.revenue - e.unit_cost - e.fixed_fees) as diff
from v_unit_economics e
where e.status='terjual'
  and coalesce(e.realized_profit,0) <> (e.revenue - e.unit_cost - e.fixed_fees)
order by abs(coalesce(e.realized_profit,0) - (e.revenue - e.unit_cost - e.fixed_fees)) desc;
-- The SUM of `diff` here = legacy_basis_diff above = the reconciliation gap.
