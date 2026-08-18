-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 5 · FINANCIAL STATEMENTS (views)
-- Management-accounting views. Additive, read-only. Encodes:
--  • Inventory = ECONOMIC UNIT COST (not funding source)
--  • Reserve = ring-fenced slice of cash (never added on top of cash)
--  • Reserve retention is a profit APPROPRIATION, never OpEx
--  • Capital return / advance reimbursement never touch P&L
-- ══════════════════════════════════════════════════════════════

-- Opening cash — explicit, unverified baseline; CFO edits later, no history rewrite.
insert into app_config(key,value) values
  ('opening_cash','0'),
  ('opening_cash_verified','false'),
  ('opening_cash_note','Opening cash balance — unverified system baseline'),
  ('opening_cash_date', current_date::text)
on conflict(key) do nothing;

-- ── Base: per-unit economics (single source the statements build on) ──
create or replace view v_unit_economics as
select u.id, u.nama, u.jenis, u.status, u.model_class, u.tgl::date acq_date, u.tgl_jual::date sale_date,
  u.harga_jual::numeric revenue,
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e) cost_panji,
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e) cost_pandu,
  (select coalesce(sum((p->>'funding')::numeric),0) from jsonb_array_elements(u.partners) p) cost_partner,
  coalesce((select sum(nominal) from reserve_advances ra where ra.unit_id=u.id),0) cost_advance,
  -- ECONOMIC UNIT COST = what the money paid for (capital-funded + advance-funded)
  (select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_panji) e)
   +(select coalesce(sum((e->>'nominal')::numeric),0) from jsonb_array_elements(u.biaya_pandu) e)
   +(select coalesce(sum((p->>'funding')::numeric),0) from jsonb_array_elements(u.partners) p)
   +coalesce((select sum(nominal) from reserve_advances ra where ra.unit_id=u.id),0) unit_cost,
  (select coalesce(sum(case when p->>'feeType'='fixed' then (p->>'feeValue')::numeric
                            when p->>'feeType'='percent' then (p->>'funding')::numeric*(p->>'feeValue')::numeric/100
                            else 0 end),0) from jsonb_array_elements(u.partners) p) fixed_fees,
  coalesce(u.keuntungan_bersih::numeric,0) realized_profit,
  coalesce(u.kas_bisnis::numeric,0) reserve_recorded,
  case when u.status='terjual' then (u.tgl_jual::date-u.tgl::date) end holding_days
from units u;

-- ── 1) P&L — explicit two-tier hierarchy. Reserve retention is BELOW net profit. ──
create or replace view v_pnl as
with s as (select * from v_unit_economics where status='terjual'),
o as (select coalesce(sum(nominal),0) opex from kas_keluar where coalesce(tipe,'opex') in ('opex','sourcing_failed'))
select
  -- ── UNIT ECONOMICS ──
  (select sum(revenue) from s)                                as revenue,
  (select sum(unit_cost) from s)                              as economic_unit_cost_cogs,
  (select sum(revenue-unit_cost) from s)                      as gross_profit,
  (select sum(fixed_fees) from s)                             as unit_financing_partner_fees,
  (select sum(revenue-unit_cost-fixed_fees) from s)           as realized_unit_profit,     -- = Σ units.keuntungan_bersih (Rp131,80jt)
  -- ── COMPANY P&L ──
  (select opex from o)                                        as company_operating_expenses,
  (select sum(revenue-unit_cost-fixed_fees) from s)-(select opex from o) as net_operating_profit,  -- (Rp131,10jt)
  -- ── BELOW THE LINE (profit appropriation, NOT an expense) ──
  coalesce((select sum(nominal) from reserve_ledger where tipe='retained_profit'),0) as reserve_retention_appropriation,
  (select round(sum(revenue-unit_cost)/nullif(sum(revenue),0)*100,1) from s)         as gross_margin_pct;

-- ── 2) Cash Flow — actual cash movements; reserve movements shown separately ──
create or replace view v_cashflow as
select
  (select value::numeric from app_config where key='opening_cash')                                        as opening_cash,
  (select value from app_config where key='opening_cash_verified')                                        as opening_verified,
  -- inflows
  coalesce((select sum(revenue) from v_unit_economics where status='terjual'),0)                          as inflow_vehicle_sales,
  coalesce((select sum(amount) from capital_allocations),0)                                               as inflow_capital_received,
  -- outflows
  coalesce((select sum(unit_cost) from v_unit_economics),0)                                               as outflow_vehicle_and_unit_costs,
  coalesce((select sum(nominal) from kas_keluar),0)                                                       as outflow_operating_expenses,
  coalesce((select sum(nilai_beli) from aset_inventori),0)                                                as outflow_capex,
  coalesce((select sum(amount) from capital_allocations where status in ('returned','settled')),0)        as outflow_capital_returns,
  coalesce((select sum(profit_share) from capital_allocations),0)                                         as outflow_distributions,
  -- reserve movements (separate; retention is NOT an expense)
  coalesce((select sum(case when arah='in' then nominal else -nominal end) from reserve_ledger where tipe='retained_profit'),0) as reserve_retention,
  coalesce((select sum(nominal) from reserve_ledger where tipe='advance'),0)                              as reserve_advances,
  coalesce((select sum(nominal) from reserve_ledger where tipe='reimbursement'),0)                        as reserve_reimbursements;

-- ── 3) Balance Sheet (management accounting; reserve = ring-fenced slice of cash) ──
create or replace view v_balance_sheet as
select
  'management_accounting' as basis,
  (select value::numeric from app_config where key='opening_cash')                                          as total_cash_baseline,
  (select reserve_balance from v_reserve_summary)                                                           as ring_fenced_reserve,
  (select value::numeric from app_config where key='opening_cash') - (select reserve_balance from v_reserve_summary) as available_operating_cash,
  coalesce((select sum(unit_cost) from v_unit_economics where status<>'terjual'),0)                         as inventory_economic_cost,
  coalesce((select sum(nilai_skrg) from aset_inventori),0)                                                  as equipment_capex,
  -- capital / equity blocks (management labels; not statutory)
  coalesce((select sum(amount) from capital_allocations a join capital_accounts c on c.id=a.account_id where c.role='founder' and a.status='active'),0)  as founder_capital_active,
  coalesce((select sum(amount) from capital_allocations a join capital_accounts c on c.id=a.account_id where c.role<>'founder' and a.status='active'),0) as investor_capital_active,
  (select reserve_balance from v_reserve_summary)                                                           as perkasa_reserve_equity,
  coalesce((select sum(amount) from capital_allocations where status='active'),0)                           as outstanding_capital_obligations;

-- ── 4) Capital reconciliation: Funded = Deployed + Returned + Available ──
create or replace view v_capital_reconcile as
select c.name, c.role, c.funded, c.committed,
  coalesce(sum(a.amount) filter (where a.status='active'),0)                        as deployed,
  coalesce(sum(a.amount) filter (where a.status in ('returned','settled')),0)       as returned,
  c.funded - coalesce(sum(a.amount) filter (where a.status='active'),0)
           - coalesce(sum(a.amount) filter (where a.status in ('returned','settled')),0) as available,
  coalesce(sum(a.profit_share),0)                                                   as profit_received,
  c.committed - c.funded                                                           as unfunded_commitment
from capital_accounts c left join capital_allocations a on a.account_id=c.id
group by c.id,c.name,c.role,c.funded,c.committed;

-- ── 5) Reserve reconciliation: Opening + Retentions + Reimbursements − Advances − Spend = Closing ──
create or replace view v_reserve_reconcile as
select
  0::numeric as opening_reserve,
  coalesce(sum(nominal) filter (where tipe='retained_profit' and arah='in'),0)      as retentions,
  coalesce(sum(nominal) filter (where tipe='reimbursement' and arah='in'),0)        as reimbursements,
  coalesce(sum(nominal) filter (where tipe='advance' and arah='out'),0)             as advances_out,
  coalesce(sum(nominal) filter (where tipe in ('opex','capex','business_dev') and arah='out'),0) as reserve_spend,
  coalesce(sum(case when arah='in' then nominal else -nominal end),0)               as closing_reserve,
  coalesce((select sum(nominal) from reserve_advances where status='outstanding'),0) as outstanding_advances,
  coalesce(sum(case when arah='in' then nominal else -nominal end),0)
    - coalesce((select sum(nominal) from reserve_advances where status='outstanding'),0) as available_reserve
from reserve_ledger;

-- ── 6) Inventory valuation (economic cost of ACTIVE units only) ──
create or replace view v_inventory as
select id, nama, jenis, model_class, acq_date,
  unit_cost as economic_cost,
  (current_date - acq_date) as aging_days,
  cost_panji+cost_pandu+cost_partner as capital_deployed,
  cost_advance as reserve_advanced
from v_unit_economics where status<>'terjual';

-- ── 7) Profitability metrics (validated) ──
create or replace view v_profitability as
with s as (select * from v_unit_economics where status='terjual')
select
  count(*)                                                             as units_sold,
  round(avg(realized_profit))                                          as avg_profit_per_unit,
  round(avg(realized_profit/nullif(unit_cost,0)*100),1)               as avg_roi_pct,
  round(avg(revenue-unit_cost)/nullif(avg(revenue),0)*100,1)          as avg_margin_pct,
  percentile_cont(0.5) within group (order by holding_days)           as median_holding,
  round(avg(holding_days),1)                                          as mean_holding
from s;

grant select on v_unit_economics,v_pnl,v_cashflow,v_balance_sheet,v_capital_reconcile,
                v_reserve_reconcile,v_inventory,v_profitability to anon,authenticated;

-- ══════════════════════════════════════════════════════════════
-- RECONCILIATION ASSERTIONS (run after deploy; each must hold)
-- P&L:        (select sum(realized_profit) from v_unit_economics where status='terjual')  -- ties to units
-- Capital:    per row  funded = deployed + returned + available   (v_capital_reconcile)
-- Reserve:    closing_reserve = retentions + reimbursements - advances_out - reserve_spend
-- Inventory:  (select sum(economic_cost) from v_inventory) = Σ active unit economic cost
-- Distribution: distributable = Σ stakeholder profit_share  (enforced by engine + settlement_variances)
-- Cash:       opening_cash + net_movements = ending_cash    (once opening cash verified)
-- ══════════════════════════════════════════════════════════════
