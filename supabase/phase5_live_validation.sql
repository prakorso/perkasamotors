-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — PHASE 5 · LIVE VALIDATION (run in Supabase SQL Editor)
-- Run AFTER deploying (in order):
--   phase3_capital_seed → phase3b_decisions → phase4_settlement_engine
--   → phase5_financial_statements
-- This single query returns all 16 checks with PASS/FAIL. Paste the result back.
-- (Settlement-engine invariant #10 is validated separately by phase4_validate.sql.)
-- ══════════════════════════════════════════════════════════════
with chk as (
  select 1 n,'Unit count' k,(select count(*)::text from units) actual,'42' expected
  union all select 2,'Historical realized profit (sold)',(select coalesce(sum(keuntungan_bersih::numeric),0)::text from units where status='terjual'),'131800000'
  union all select 3,'Capital allocation total',(select coalesce(sum(amount),0)::text from capital_allocations),'847500000'
  union all select 4,'Capital recon mismatches (funded=dep+ret+avail)',(select count(*)::text from v_capital_reconcile where round(funded)<>round(deployed+returned+available)),'0'
  union all select 5,'Reserve closing balance',(select closing_reserve::text from v_reserve_reconcile),'1700000'
  union all select 6,'Inventory economic cost (active)',(select coalesce(sum(economic_cost),0)::text from v_inventory),'98000000'
  union all select 7,'P&L Realized Unit Profit',(select realized_unit_profit::text from v_pnl),'131800000'
  union all select 8,'P&L Net Operating Profit',(select net_operating_profit::text from v_pnl),'131100000'
  union all select 9,'Opening cash (unverified baseline)',(select value from app_config where key='opening_cash'),'0'
  union all select 10,'Distribution total (recorded, preserved)',(select coalesce(sum(profit_share),0)::text from capital_allocations),'171909600'
  union all select 11,'#35/37/38 current + transition_recorded',(select count(*)::text from units where id in(35,37,38) and model_class='current' and settlement_status='transition_recorded'),'3'
  union all select 12,'#35/37/38 kas preserved',(select string_agg(kas_bisnis::text,'/' order by id) from units where id in(35,37,38)),'800000/800000/100000'
  union all select 13,'#37 unresolved variance',(select coalesce(sum(amount),0)::text from settlement_variances where unit_id=37 and status='unresolved'),'50000'
  union all select 14,'#39/41/42 legacy',(select count(*)::text from units where id in(39,41,42) and model_class='legacy'),'3'
  union all select 15,'Financial policy rate = 10%',(select (rate=0.10)::text from financial_policy where status='active' order by effective_date desc limit 1),'true'
  union all select 16,'Historical financial cols changed vs backup',
    (select count(*)::text from units u join units_bak_20260818 b on b.id=u.id
      where u.harga_jual::numeric<>b.harga_jual::numeric
         or coalesce(u.keuntungan_bersih::numeric,-999)<>coalesce(b.keuntungan_bersih::numeric,-999)
         or coalesce(u.kas_bisnis::numeric,-999)<>coalesce(b.kas_bisnis::numeric,-999)
         or coalesce(u.bagi_panji::numeric,-999)<>coalesce(b.bagi_panji::numeric,-999)
         or coalesce(u.bagi_pandu::numeric,-999)<>coalesce(b.bagi_pandu::numeric,-999)
         or u.biaya_panji<>b.biaya_panji or u.biaya_pandu<>b.biaya_pandu or u.partners<>b.partners),'0'
)
select n as "#", k as check, actual, expected,
       case when actual=expected then 'PASS ✅' else 'FAIL ❌' end as status
from chk order by n;
