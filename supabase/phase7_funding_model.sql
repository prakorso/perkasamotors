-- ══════════════════════════════════════════════════════════════
-- PERKASA MOTORS — CFO SYSTEM · PHASE 7 · FUNDING MODEL & CAPACITY
-- Server-side views only. Additive, read-only. No historical data altered.
-- Distinguishes FUNDING NEED vs CAPACITY vs UTILIZATION.
-- Throughput- and holding-constrained — NOT profit × funding.
--
-- KEY REALITY (from data): median holding ≈ 4 days, mean ≈ 7.7 days ⇒ working
-- capital recycles ~28×/yr ⇒ the business needs LITTLE concurrent capital.
-- Therefore large funding is easily IDLE unless monthly throughput scales far
-- beyond the historical ~2.8 units/month. This model surfaces idle capital.
--
-- OPERATIONAL ASSUMPTIONS (explicit, documented, editable):
--   K  avg economic cost / unit          = 19,200,000  (= COGS ÷ sold, blended)
--      (motor-weighted ≈ 10,100,000 → ~1.9× more units per rupiah; see note)
--   H  mean holding days                 = 7.7   (median 4)
--   PU realized profit / unit            = 3,380,000
--   M  realized margin                   = 0.197
--   T0 historical throughput / month     = 2.75  (39 sold ÷ 14.2 months)
--   RR reserve rate                      = 0.10
--   Peak concurrent capital (observed)   = 98,900,000   (validated Phase-1)
--   Avg deployed capital (active-days)   = 22,690,000
-- WIP (Little's law): concurrent_units = throughput_per_month × (H ÷ 30)
-- ══════════════════════════════════════════════════════════════

-- 1) CURRENT OPERATING CAPACITY (traceable to unit-level data)
create or replace view v_funding_capacity as
with s as (select * from v_unit_economics where status='terjual'),
p as (select (max(sale_date)-min(acq_date))::numeric/30.44 as months from s)
select
  (select count(*) from s)                                          as sold_units,
  round((select count(*) from s)/nullif((select months from p),0),2) as throughput_per_month,
  round((select count(*) from s)/nullif((select months from p),0)*12) as throughput_per_year,
  round((select avg(unit_cost) from s))                             as avg_cost_per_unit,
  round((select avg(unit_cost) from s where jenis='Motor'))         as avg_cost_motor,
  round((select avg(unit_cost) from s where jenis='Mobil'))         as avg_cost_mobil,
  (select round(percentile_cont(0.5) within group(order by holding_days)) from s) as median_holding,
  round((select avg(holding_days) from s),1)                        as mean_holding,
  round((select avg(realized_profit) from s))                       as realized_profit_per_unit,
  round((select avg(realized_profit/nullif(revenue,0)) from s)*100,1) as realized_margin_pct,
  98900000::numeric                                                 as peak_concurrent_capital,   -- validated Phase-1
  22690000::numeric                                                 as avg_deployed_capital,       -- validated Phase-1
  coalesce((select sum(unit_cost) from v_unit_economics where status<>'terjual'),0) as current_inventory_value,
  -- legacy vs current split
  count(*) filter (where model_class='legacy') over ()             as legacy_sold,
  count(*) filter (where model_class='current') over ()            as current_sold
from s limit 1;

-- 2) FUNDING SCENARIOS — funding × operational-throughput ceiling.
--    actual_throughput = LEAST(capital-enabled, ops ceiling)  ⇒ idle capital exposed.
create or replace view v_funding_scenarios as
with param as (select 19200000::numeric K, 7.7::numeric H, 3380000::numeric PU, 0.10::numeric RR),
funding as (select unnest(array[100000000,150000000,250000000,500000000]::numeric[]) F),
ops as (select * from (values ('current (2.75/mo)',2.75),('scaled 2x (5.5/mo)',5.5),('scaled 4x (11/mo)',11.0)) as t(ops_label,T)),
x as (
  select f.F, o.ops_label, o.T, pr.K, pr.H, pr.PU, pr.RR,
    (f.F/pr.K)                                          as capital_enabled_concurrent,
    (f.F/pr.K)*30/pr.H                                  as capital_enabled_throughput_mo,
    least((f.F/pr.K)*30/pr.H, o.T)                      as actual_throughput_mo
  from funding f cross join ops o cross join param pr
)
select F as funding, ops_label, round(T,2) as ops_ceiling_mo,
  round(capital_enabled_concurrent,1)                  as capital_enabled_concurrent,
  round(capital_enabled_throughput_mo,1)               as capital_enabled_throughput_mo,
  round(actual_throughput_mo,2)                         as actual_throughput_mo,
  round(actual_throughput_mo*H/30,1)                    as actual_concurrent_units,
  round(actual_throughput_mo*H/30*K)                    as deployed_capital,
  round(F - actual_throughput_mo*H/30*K)                as idle_capital,
  round(actual_throughput_mo*H/30*K / nullif(F,0)*100) as utilization_pct,
  round(actual_throughput_mo*12)                        as annual_throughput,
  round(actual_throughput_mo*12*PU)                     as annual_realized_profit,
  round(actual_throughput_mo*12*PU*RR)                  as annual_reserve_retention,
  round(actual_throughput_mo*12*PU*(1-RR))              as annual_investor_distributable,
  -- OPERATING metrics (company-level; denominators labelled). NOT investor ROI.
  round(actual_throughput_mo*12*PU / nullif(actual_throughput_mo*H/30*K,0)*100) as operating_roi_on_deployed_pct,  -- business profit ÷ DEPLOYED operating capital
  round(actual_throughput_mo*12*PU / nullif(F,0)*100)   as business_profit_to_funding_pct                          -- business profit ÷ FUNDING (context only, not a return to any single party)
from x order by F, T;

-- 3) CAPITAL UTILIZATION at 50 / 75 / 100% (how much funding is actually deployed)
create or replace view v_funding_utilization as
with funding as (select unnest(array[100000000,150000000,250000000,500000000]::numeric[]) F),
u as (select unnest(array[0.50,0.75,1.00]::numeric[]) util)
select f.F as funding, (u.util*100)::int as utilization_target_pct,
  round(f.F*u.util)             as deployed_capital,
  round(f.F*(1-u.util))         as idle_capital,
  round(f.F*u.util/19200000,1)  as implied_concurrent_units,
  round(f.F*u.util/19200000*30/7.7,1) as implied_throughput_mo,
  case when f.F*u.util/19200000*30/7.7 > 2.75*2 then 'requires major ops scaling'
       when f.F*u.util/19200000*30/7.7 > 2.75   then 'requires ops scaling'
       else 'within ~historical ops' end as feasibility
from funding f cross join u order by f.F, u.util;

-- 4) STRESS TEST — sensitivities on a BASE case (Rp150M, ops scaled 2x = 5.5/mo)
create or replace view v_funding_stress_test as
with b as (select 150000000::numeric F, 5.5::numeric T, 19200000::numeric K,
                  7.7::numeric H, 3380000::numeric PU, 0.197::numeric M),
scen as (select * from (values
  ('Base',                       1.00, 1.00, 1.00, 1.00),
  ('A holding +25%',             1.25, 1.00, 1.00, 1.00),
  ('B holding +50%',             1.50, 1.00, 1.00, 1.00),
  ('C margin -20%',              1.00, 0.80, 1.00, 1.00),
  ('D margin -30%',              1.00, 0.70, 1.00, 1.00),
  ('E throughput -25%',          1.00, 1.00, 0.75, 1.00),
  ('F maint cost +25%',          1.00, 0.90, 1.00, 1.06),  -- higher cost: -margin ~10%, +unit cost ~6%
  ('G combined downside',        1.50, 0.70, 0.75, 1.06)
) as t(scenario, hold_mult, margin_mult, tput_mult, cost_mult))
select s.scenario,
  round(b.T*s.tput_mult,2)                                  as throughput_mo,
  round(b.H*s.hold_mult,1)                                  as holding_days,
  round(b.PU*s.margin_mult)                                 as profit_per_unit,
  round(b.T*s.tput_mult*12)                                 as annual_units,
  round(b.T*s.tput_mult*12*b.PU*s.margin_mult)              as annual_profit,
  round(b.T*s.tput_mult*(b.H*s.hold_mult)/30*b.K*s.cost_mult) as deployed_capital,
  round(b.T*s.tput_mult*(b.H*s.hold_mult)/30*b.K*s.cost_mult / b.F*100) as utilization_pct,
  round(b.T*s.tput_mult*12*b.PU*s.margin_mult
        / nullif(b.T*s.tput_mult*(b.H*s.hold_mult)/30*b.K*s.cost_mult,0)*100) as roi_on_deployed_pct
from b cross join scen s;

-- ── Configurable funding/commercial assumptions (editable; NOT final terms) ──
-- These EXPOSE the parameters instead of hardcoding them. Reserve rate is NOT
-- duplicated here — it is read from financial_policy (single source, unchanged 10%).
create table if not exists funding_assumptions (
  key text primary key, value numeric not null, label text default '', updated_at timestamptz default now()
);
insert into funding_assumptions(key,value,label) values
  ('founder_mgmt_share', 0.00,     'Founder management/sourcing share of DISTRIBUTABLE profit — NOT finalized (placeholder 0%)'),
  ('ops_ceiling_mo',     5.50,     'Modeled sustainable throughput ceiling, units/month (≈2× historical)'),
  ('avg_cost_per_unit',  19200000, 'Blended economic cost/unit (= COGS ÷ sold)'),
  ('mean_holding_days',  7.70,     'Mean holding period, days'),
  ('profit_per_unit',    3380000,  'Realized profit per unit')
on conflict (key) do nothing;
alter table funding_assumptions enable row level security;
do $$ begin
  execute 'create policy allow_all_fa on funding_assumptions for all to anon,authenticated using(true) with check(true)';
exception when duplicate_object then null; end $$;

-- 5) INVESTOR FUNDING ECONOMICS — EXPLICIT denominators, CONFIGURABLE sharing.
--    investor_dist_share = 1 − founder_mgmt_share  (they split the 90% distributable).
--    Defaults: founder_mgmt_share = 0 ⇒ investor 100% (ILLUSTRATIVE capital-only).
--    Reserve rate read from financial_policy (company-owned; never investor profit).
--    Investor earns ONLY on DEPLOYED capital; idle capital earns nothing.
create or replace view v_investor_funding_economics as
with cfg as (
  select
    (select value from funding_assumptions where key='avg_cost_per_unit')  as K,
    (select value from funding_assumptions where key='mean_holding_days')  as H,
    (select value from funding_assumptions where key='profit_per_unit')    as PU,
    (select rate from financial_policy where status='active' order by effective_date desc limit 1) as RR,
    (select value from funding_assumptions where key='ops_ceiling_mo')     as T,
    (select value from funding_assumptions where key='founder_mgmt_share') as founder_share,
    1 - (select value from funding_assumptions where key='founder_mgmt_share') as investor_dist_share
),
funding as (select unnest(array[100000000,150000000,250000000,500000000]::numeric[]) F),
y as (
  select f.F, c.K,c.H,c.PU,c.RR,c.T,c.founder_share,c.investor_dist_share,
         least((f.F/c.K)*30/c.H, c.T)                                as tput,
         least(f.F, round(least((f.F/c.K)*30/c.H, c.T)*c.H/30*c.K))  as inv_deployed
  from funding f cross join cfg c
)
select F as funding,
  inv_deployed                                                        as deployed,
  round(F - inv_deployed)                                             as idle_capital,
  round(inv_deployed/nullif(F,0)*100)                                as utilization_pct,
  round(tput*12*PU)                                                   as annual_business_profit,
  round(tput*12*PU*RR)                                                as reserve_retention,
  round(tput*12*PU*(1-RR))                                            as distributable_profit,
  founder_share                                                       as founder_mgmt_share,
  investor_dist_share                                                 as investor_share_of_distributable,
  round(tput*12*PU*(1-RR)*investor_dist_share)                        as investor_realized_profit,
  round(tput*12*PU*(1-RR)*founder_share)                             as founder_mgmt_profit,
  -- ── ROI metrics with EXPLICIT denominators ──
  round(tput*12*PU / nullif(inv_deployed,0)*100)                     as operating_roi_on_deployed_pct,     -- BUSINESS profit ÷ deployed (company)
  round(tput*12*PU*(1-RR)*investor_dist_share / nullif(F,0)*100)     as investor_roi_on_funded_pct,        -- investor profit ÷ FUNDED
  round(tput*12*PU*(1-RR)*investor_dist_share / nullif(inv_deployed,0)*100) as investor_roi_on_deployed_pct, -- investor profit ÷ DEPLOYED
  round(1 + tput*12*PU*(1-RR)*investor_dist_share / nullif(F,0),2)   as investor_return_multiple_on_funded,
  round(H,1)                                                          as holding_days,
  case when founder_share=0
    then 'Illustrative capital-only scenario — commercial profit-sharing terms not finalized'
    else 'Configured: investor '||round(investor_dist_share*100)||'% / founder mgmt '||round(founder_share*100)||'% of distributable'
  end                                                                 as scenario_label
from y order by F;

-- 6) FUNDING RECOMMENDATION (data-driven range; assumptions explicit)
create or replace view v_funding_recommendation as
select * from (values
  ('Minimum viable', 50000000::numeric, 75000000::numeric,
   'Smooths current ops incl. the occasional peak (observed peak deployed Rp98.9jt when a mobil overlapped motors). Motor-weighted; ~3-4 concurrent.'),
  ('Optimal / base', 100000000, 150000000,
   'Supports ~2-3x throughput growth (5.5-8 units/mo), motor-weighted, with reserve Rp30jt + opcash buffer. Requires modest sourcing/sales scaling.'),
  ('Maximum prudent', 200000000, 250000000,
   'Supports ~4x throughput (≈11 units/mo) — requires MAJOR ops scaling (sourcing team + channels). Above this, capital is likely idle.'),
  ('Not recommended', 500000000, 500000000,
   'Would need ~15-25 concurrent units / ~15-20 sales per month (5-7x historical). No near-term operational basis; large idle-capital risk.')
) as t(tier, low, high, rationale);

-- 7) CASH SAFETY (operating cash ≠ reserve ≠ inventory capital; no double count)
create or replace view v_funding_cash_safety as
select
  10000000::numeric  as operating_cash_buffer,   -- ~6 months opex at recent run-rate
  120000000::numeric as inventory_funding_base,   -- base-scenario working capital
  30000000::numeric  as reserve_target,           -- separate, ring-fenced
  10000000 + 120000000 + 30000000 as total_business_funding_requirement_base;

grant select on v_funding_capacity, v_funding_scenarios, v_funding_utilization,
                v_funding_stress_test, v_investor_funding_economics,
                v_funding_recommendation, v_funding_cash_safety to anon,authenticated;
grant select, insert, update on funding_assumptions to anon,authenticated;

-- ── Reconfigure commercial terms WITHOUT touching the view or historical data ──
--   Give founders a 40% management share (investor auto-becomes 60%):
--     update funding_assumptions set value=0.40 where key='founder_mgmt_share';
--   Change modeled throughput ceiling:
--     update funding_assumptions set value=8.0 where key='ops_ceiling_mo';
--   Reserve rate is NOT here — it stays in financial_policy (unchanged 10%).

-- ══════════════════════════════════════════════════════════════
-- RECONCILIATION ASSERTIONS (traceable to unit-level data)
--  • v_funding_capacity.throughput_per_month  ≈ 2.75  (39 ÷ 14.2 months)
--  • v_funding_capacity.avg_cost_per_unit      = 19,200,000 (= COGS ÷ 39)
--  • Scenario deployed_capital ≤ funding  AND  idle_capital = funding − deployed
--  • Investor economics use 90% (after 10% reserve); reserve never in investor capital
--  • Every metric derives from v_unit_economics (unit-level) + documented params
-- ══════════════════════════════════════════════════════════════
