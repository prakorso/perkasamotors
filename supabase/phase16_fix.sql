-- ══════════════════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 16 FIX · v_unit_pnl_unified legacy basis
-- Re-apply the corrected view so legacy retained ties to validated v_pnl, then
-- re-check the one assertion that failed. Additive; touches only the new view.
-- ══════════════════════════════════════════════════════════════════════════
create or replace view v_unit_pnl_unified as
select 'legacy'::text as source, e.id as unit_id, e.nama, e.sale_date as pnl_date,
       e.revenue, e.unit_cost as base_cost, 0::numeric as selling_cost,
       (e.revenue - e.unit_cost - e.fixed_fees) as true_profit,
       (e.revenue - e.unit_cost - e.fixed_fees) as retained_profit, false as is_loss
from v_unit_economics e where e.status='terjual'
union all
select 'future'::text, s.unit_id, u.nama, s.settle_date,
       s.selling_price, s.base_unit_cost_snap, s.selling_cost,
       s.true_unit_profit, s.perkasa_retained_profit, s.is_loss
from unit_settlement s join units u on u.id=s.unit_id where s.status='settled';

-- Re-check: with no future settlements now, all-time unified legacy must equal v_pnl.
select
  (fn_pnl('1900-01-01', current_date)->>'unit_retained')::numeric as unified_alltime,
  (select realized_unit_profit from v_pnl)                        as v_pnl_realized,
  (select total_retained from v_retained_profit)                 as retained_total,
  ((fn_pnl('1900-01-01', current_date)->>'unit_retained')::numeric = (select total_retained from v_retained_profit)) as ties_now;
-- Expect: unified_alltime = v_pnl_realized = retained_total = 138300000, ties_now = true.
